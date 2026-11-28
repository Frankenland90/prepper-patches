#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-lageohnesdr: Lage ohne SDR_OFFLINE, korrigierter 5C-Fix (Telemetrie-Deadlock).

Ursache (apply-atis 5C-Teil, prepper_sdr f2cfa954): _ff7b_note() nahm self.lock,
während Planner.status() denselben nicht-rekursiven threading.Lock bereits hält
(status ruft bc_queue -> _ff7b_note). Der Planer-Faden hängt still, sdr_status.json
wird nicht mehr geschrieben, das Dashboard zeigt nach 15 s SDR_OFFLINE. systemd
bleibt active (eigener Watchdog-Takt). Kein Traceback.

Dieser Lauf:
1. Lage-Ampel: SDR_OFFLINE macht die Lage nicht mehr auffaellig und laesst sie
   nicht blinken. Echte Warnlagen (Echtalarm, Probe, Vor-Alarm Netz/DSL) bleiben.
2. Hinweis nur auf /funk (SDR-Kachel, gelb, ohne Blinken der Lage).
3. Neustart-Karenz 120 s: nach Start von prepper-sdr kein OFFLINE-Hinweis.
4. 5C-Fix neu auf Basis 86da726a (bak-atis) bzw. Hotfix von f2cfa954: kein
   Doppelstart, Versuch 90 s, sdrLog/Stick 1, ASA-Rueckfallzeile. _ff7b_note
   ohne Planner.lock. _sf_skip unveraendert (kein fail-closed).
5. Beide prepper_sdr-Startstaende enden auf demselben Hash. dashboard 54fda6e0.

Muster: Hash-Waechter, --dry-run/--kein-neustart/--selftest, Backup .bak-lageohnesdr-<ts>,
atomic + copymode + chown auf urspruengliche uid/gid, ehrlicher systemctl-Check,
45 s Live-Warten, Fenster 05-39 (Berlin). Selbsttest prueft Telemetrie-Takt unter Lock.
Nichts wird hier auf den Pi geschrieben.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import threading
import time
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "lageohnesdr"
BASIS = "/home/fmg/prepper-dashboard"
DIENSTE_SDR = "prepper-sdr"
DIENSTE_DASH = "prepper-dashboard"

# prepper_sdr: bak-atis / apply-acars-Endstand ODER apply-atis-Endstand (Deadlock)
SDR_START_ACARS = "86da726a0fae96630e2a132f8ac2e8221bb3bd8e483ddb6b9b00fe1ee8d19637"
SDR_START_ACARS16 = "86da726a0fae9663"
SDR_START_ACARS_B = 803996
SDR_START_ATIS = "f2cfa954190cafe3fa8ddf403540194eb79000910c10d52228bb7e0c7278070f"
SDR_START_ATIS16 = "f2cfa954190cafe3"
SDR_START_ATIS_B = 806124
SDR_END_SHA = "9ac15b0981b91f80236ce847c7a77fc081877a786f01e7c99422a1b8e13e0e30"
SDR_END_SHA16 = "9ac15b0981b91f80"
SDR_END_BYTES = 806307

# dashboard nach apply-atis
DASH_START_SHA = "54fda6e066f4b3441c0c9dc240ef557fb0681001f663d3dd3791b6310dcbec20"
DASH_START_SHA16 = "54fda6e066f4b344"
DASH_START_BYTES = 1397857
DASH_END_SHA = "c9bd7612a06dc290f91a4e826b16ab3b944a87a0ab51407be67bcc5e7e121af7"
DASH_END_SHA16 = "c9bd7612a06dc290"
DASH_END_BYTES = 1401463

# unveraendert
KACHEL_SHA16 = "68f52f16"
KACHEL_BYTES = 38999
EDDN_SHA16 = "0420d632"
EDDN_BYTES = 46475
FF_SHA16 = "5d7c1e27"
FF_BYTES = 100944


SDR_FF7B_ALT = 'def _ff7b_bc_queue(self):\n    """Stick Rolle 5C: ASA 5C hat Vorrang. Nur wenn 5C keinen frischen Sync hat, 10C;\n    5C wird trotzdem alle 10 min (T4_RETRY_S) mit vollem Block erneut geprueft.\n    Verhindert, dass ein alter 10C-Sync 5C dauerhaft verdraengt (cpulimit-Ausfall 26.11.)."""\n    q = _ff7b_orig_bc(self)\n    try:\n        a = _air_pl(self)\n        if not a or a.get("role") != "5C":\n            return q\n        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}\n        lst = [str(x) for x in self.dab_list()]\n        if "5C" not in lst:\n            return q\n        now = time.time()\n        dur = float(self.cfg.get("dab_s") or 60)\n        i5 = lst.index("5C")\n        i10 = lst.index("10C") if "10C" in lst else None\n        if _ff7b_fresh(dab.get("5C"), now):\n            return [("dab:%d" % i5, dur)]\n        last = float(self.__dict__.get("_ff7b_last5c") or 0)\n        due = True if not last else (now - last) >= float(T4_RETRY_S)\n        if due:\n            return [("dab:%d" % i5, dur)]\n        if i10 is not None and _ff7b_fresh(dab.get("10C"), now):\n            return [("dab:%d" % i10, dur)]\n    except Exception:\n        return q\n    return q\n'

SDR_FF7B_NEU = 'T5C_TRY_S = 90  # volle 5C-Pruefung, nicht durch Doppelstart kuerzen\n\n\ndef _ff7b_ch(self):\n    act = _s(getattr(self, "active", None))\n    if not act.startswith("dab:"):\n        return ""\n    try:\n        lst = [str(x) for x in self.dab_list()]\n        i = int(act[4:])\n        return lst[i] if i < len(lst) else ""\n    except Exception:\n        return ""\n\n\ndef _ff7b_is_fb(self, now=None):\n    """True, wenn der 5C-Planer im gewollten 10C-Rueckfall ist (kein frischer 5C-Sync)."""\n    now = time.time() if now is None else float(now)\n    try:\n        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}\n        if _ff7b_fresh(dab.get("5C"), now):\n            return False\n        if _ff7b_ch(self) == "10C":\n            return True\n        last = float(self.__dict__.get("_ff7b_last5c") or 0)\n        if last and (now - last) < float(T4_RETRY_S):\n            return True\n    except Exception:\n        pass\n    return False\n\n\ndef _ff7b_note(self, now=None):\n    now = time.time() if now is None else float(now)\n    try:\n        last = float(self.__dict__.get("_ff7b_last5c") or 0)\n        fb = _ff7b_is_fb(self, now)\n        rec = {\n            "v": 1, "fb": bool(fb),\n            "last5c": int(last) if last else None,\n            "next": int(last + T4_RETRY_S) if last and fb else None,\n            "try_s": int(T5C_TRY_S), "t": int(now),\n        }\n        sbc = getattr(self, "sbc", None)\n        if sbc is None:\n            return\n        # kein Planner.lock: status()/sched()/lage_shares() rufen bc_queue bereits\n        # unter diesem Lock auf (threading.Lock ist nicht rekursiv).\n        # Ein erneutes Sperren hier haengt den Planer -> keine Telemetrie, SDR_OFFLINE.\n        sbc.d["fb5c"] = rec\n        sbc.dirty = True\n    except Exception as ex:\n        print("ff7b note:", type(ex).__name__, flush=True)\n\n\ndef _ff7b_bc_queue(self):\n    """Stick Rolle 5C: ASA 5C hat Vorrang. Nur wenn 5C keinen frischen Sync hat, 10C;\n    5C wird trotzdem alle 10 min (T4_RETRY_S) mit vollem Block (T5C_TRY_S, 90 s) erneut geprueft.\n    Kein Doppelstart, wenn 5C schon laeuft (auch wenn sich der Queue-Index aendert)."""\n    q = _ff7b_orig_bc(self)\n    try:\n        a = _air_pl(self)\n        if not a or a.get("role") != "5C":\n            return q\n        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}\n        lst = [str(x) for x in self.dab_list()]\n        if "5C" not in lst:\n            return q\n        now = time.time()\n        dur = float(self.cfg.get("dab_s_5c") or T5C_TRY_S)\n        act = _s(getattr(self, "active", None))\n        if act.startswith("dab:") and self.procs and self.alive() and _ff7b_ch(self) == "5C":\n            _ff7b_note(self, now)\n            return [(act, dur)]\n        i5 = lst.index("5C")\n        i10 = lst.index("10C") if "10C" in lst else None\n        if _ff7b_fresh(dab.get("5C"), now):\n            _ff7b_note(self, now)\n            return [("dab:%d" % i5, dur)]\n        last = float(self.__dict__.get("_ff7b_last5c") or 0)\n        due = True if not last else (now - last) >= float(T4_RETRY_S)\n        if due:\n            _ff7b_note(self, now)\n            return [("dab:%d" % i5, dur)]\n        if i10 is not None and _ff7b_fresh(dab.get("10C"), now):\n            _ff7b_note(self, now)\n            return [("dab:%d" % i10, dur)]\n        _ff7b_note(self, now)\n    except Exception:\n        return q\n    return q\n\n\n'

SDR_SUB_ALT = 'def _ff7b_sub_done(self, sp, now):\n    try:\n        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") is not None else ""\n        if _s(job).startswith("dab:"):\n            lst = [str(x) for x in self.dab_list()]\n            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else ""\n            if ch == "5C":\n                self.__dict__["_ff7b_last5c"] = float(now)\n    except Exception:\n        pass\n    return _ff7b_orig_sub(self, sp, now)\n'

SDR_SUB_NEU = 'def _ff7b_sub_done(self, sp, now):\n    try:\n        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") is not None else ""\n        if _s(job).startswith("dab:"):\n            lst = [str(x) for x in self.dab_list()]\n            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else ""\n            if ch == "5C":\n                self.__dict__["_ff7b_last5c"] = float(now)\n        _ff7b_note(self, now)\n    except Exception:\n        pass\n    return _ff7b_orig_sub(self, sp, now)\n\n\n'

SDR_WATCH_ALT = '        st4 = self.__dict__.get("_t4")\n        fb = bool(st4.get("fb")) if isinstance(st4, dict) else False\n        with _SDRLOG_LOCK:\n            tl = sdrlog_get(self.base)\n            if tl.stick(bool(to.get("on")), to, _sf_fb(self, tl, fb, now), al, now):\n                tl.save()\n'

SDR_WATCH_NEU = '        fb = _ff7b_is_fb(self, now)\n        sync = False\n        try:\n            dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}\n            sync = _ff7b_fresh(dab.get("5C"), now)\n        except Exception:\n            sync = False\n        with _SDRLOG_LOCK:\n            tl = sdrlog_get(self.base)\n            if tl.stick(bool(to.get("on")), to, _sf_fb(self, tl, fb, now), sync, now):\n                tl.save()\n'

SDR_WATCHIF_ALT = '        if getattr(self, "role", None) != "rot" or not t2_on(self) or _sf_skip(self):\n            return\n'

SDR_WATCHIF_NEU = '        if _sf_skip(self):\n            return\n'

NOTE_LOCK_ALT = '        with self.lock:\n            sbc.d["fb5c"] = rec\n            sbc.dirty = True\n            sbc.last_saved = 0\n'

NOTE_LOCK_NEU = '        # kein Planner.lock: status()/sched()/lage_shares() rufen bc_queue bereits\n        # unter diesem Lock auf (threading.Lock ist nicht rekursiv).\n        # Ein erneutes Sperren hier haengt den Planer -> keine Telemetrie, SDR_OFFLINE.\n        sbc.d["fb5c"] = rec\n        sbc.dirty = True\n'

SKIP_BAD = '    return not (a and a.get("role") == "5C")\n'

SKIP_OK = '    return a is not None and a.get("role") != "5C"\n'

LOS_FUNCS = 'LOS_GRACE_S = 120  # nach prepper-sdr-Start kein OFFLINE-Hinweis\n\n\ndef _los_sdr_age(now):\n    """Alter des prepper-sdr-Prozesses in Sekunden, oder None. Im Selftest (fake) nie."""\n    if (_T4.get("fake") or {}):\n        return None\n    now = float(now)\n    cache = _T4.get("_los_age")\n    if isinstance(cache, tuple) and now - cache[0] < 5:\n        return cache[1]\n    age = None\n    try:\n        r = __import__("subprocess").run(\n            ["systemctl", "show", "prepper-sdr", "-p", "MainPID", "-p", "ActiveState"],\n            capture_output=True, text=True, timeout=2)\n        pid, active = 0, ""\n        for ln in (r.stdout or "").splitlines():\n            if ln.startswith("MainPID="):\n                pid = int(ln.split("=", 1)[1] or 0)\n            elif ln.startswith("ActiveState="):\n                active = ln.split("=", 1)[1].strip()\n        if active == "active" and pid > 1:\n            with open("/proc/%d/stat" % pid, encoding="utf-8", errors="replace") as fh:\n                st = fh.read()\n            rpar = st.rfind(")")\n            parts = st[rpar + 1:].split() if rpar >= 0 else st.split()\n            start = float(parts[19])  # starttime ticks after boot (field 22, nach ) = Index 19)\n            hz = float(__import__("os").sysconf("SC_CLK_TCK") or 100)\n            with open("/proc/uptime", encoding="utf-8") as fh:\n                up = float(fh.read().split()[0])\n            age = max(0.0, up - start / hz)\n    except Exception:\n        age = None\n    _T4["_los_age"] = (now, age)\n    return age\n\n\ndef _los_grace(now):\n    age = _los_sdr_age(now)\n    return age is not None and 0 <= age < LOS_GRACE_S\n\n\ndef _los_lage(lvl, live, now=None, base=None):\n    """SDR_OFFLINE / Technikstoerung darf die Lage nicht auffaellig machen oder blinken."""\n    lvl = dict(lvl or {})\n    if lvl.get("lvl") == "alarm":\n        return lvl\n    sdr = (live == "SDR_OFFLINE") or (lvl.get("lvl") == "offline") or (lvl.get("label") == "SDR_OFFLINE")\n    if not sdr:\n        return lvl\n    why = str(lvl.get("why") or "")\n    lab = str(lvl.get("label") or "")\n    if lvl.get("lvl") == "pre" or "VORALARM" in lab or "NETZ" in why or "DSL" in why:\n        if lab == "SDR_OFFLINE":\n            lvl["label"] = "VORALARM NETZFREQUENZ" if "NETZ" in why else "VORALARM DSL-AUSFALL"\n            lvl["lvl"] = "pre"\n        return lvl\n    if lvl.get("lvl") == "probe":\n        return lvl\n    lvl["lvl"] = "ok"\n    lvl["label"] = "OK"\n    lvl["blink"] = False\n    lvl["color"] = "#22c55e"\n    lvl["why"] = "kein echter Alarm, keine ASA-Probe – SDR-Technik gesondert (nicht die Lage)"\n    notes = list(lvl.get("notes") or [])\n    notes.append("SDR_OFFLINE nicht in der Lage")\n    lvl["notes"] = notes\n    return lvl\n\n\ndef _los_hint(live, now):\n    """Hinweis fuer /funk SDR-Kachel. Waehrend Karenz kein OFFLINE."""\n    if live != "SDR_OFFLINE":\n        return None, live\n    if _los_grace(now):\n        return "prepper-sdr startet (Karenz %d s, kein OFFLINE)" % LOS_GRACE_S, "STARTING"\n    return "keine frische Telemetrie von prepper-sdr (Watchdog 15 s) – nur Systemhinweis, nicht die Lage", live\n\n\n'

DASH_INSERT_BEFORE = 'def _t4_status_calc(now=None):\n'

DASH_LVL_ALT = '    lvl = _lz_mgr.t4_level(live_st, al, st["pre"], br)\n    sd = _lz_mgr.t4_sdr(base, now)\n    lvl = globals().get("_wd_t4", lambda a, *b: a)(lvl, sd, base, now)   # sdrWd: echter SDR-Zustand im Lage-Text (Stufe/Label/Mesh unveraendert) + Alarm-Sperre\n'

DASH_LVL_NEU = '    lvl = _lz_mgr.t4_level(live_st, al, st["pre"], br)\n    sd = _lz_mgr.t4_sdr(base, now)\n    lvl = globals().get("_wd_t4", lambda a, *b: a)(lvl, sd, base, now)   # sdrWd: echter SDR-Zustand im Lage-Text (Stufe/Label/Mesh unveraendert) + Alarm-Sperre\n    lvl = _los_lage(lvl, live_st, now, base)\n'

DASH_RET_ALT = '    _T4["status"], _T4["status_t"] = s, now\n    return s\n'

DASH_RET_NEU = '    s["sdr_hint"], _live2 = _los_hint(live_st, now)\n    if _live2 != live_st:\n        s["live"] = _live2\n    _T4["status"], _T4["status_t"] = s, now\n    return s\n'

DASH_ST_ALT = '        fk["alarms"], fk["live"] = [], "SDR_OFFLINE"\n        lv = _t4_status_calc(clock[0])["level"]\n        assert lv["lvl"] == "offline" and lv["blink"] and lv["color"] == "#f97316"\n        fk["live"] = "OK"\n'

DASH_ST_NEU = '        fk["alarms"], fk["live"] = [], "SDR_OFFLINE"\n        lv = _t4_status_calc(clock[0])["level"]\n        assert lv["lvl"] == "ok" and not lv["blink"] and lv.get("label") == "OK", lv\n        st_off = _t4_status_calc(clock[0])\n        assert st_off.get("sdr_hint") or st_off.get("live") in ("SDR_OFFLINE", "STARTING"), st_off\n        fk["live"] = "OK"\n'

DASH_JS_ALT = "var tr=D.tr||null;L[6].textContent=tr?(tr.line||''):'';L[6].style.color=(tr&&tr.ok)?'#64748b':'#fdba74';\n"

DASH_JS_NEU = "var tr=D.tr||null;L[6].textContent=tr?(tr.line||''):'';L[6].style.color=(tr&&tr.ok)?'#64748b':'#fdba74';\nif(D.sdr_hint){if(!t._hi){t._hi=line(t);t._hi.style.fontWeight='600';}t._hi.textContent=D.sdr_hint;t._hi.style.color='#eab308';t._hi.style.display='';}else if(t._hi){t._hi.style.display='none';t._hi.textContent='';}\n"

SDR_MSG = [('"Stick 2 Rückfall 10C (Lokal Nürnberg): 5C ohne Sync nach %d Prüfungen, 5C-Versuch alle %d min" % (T4_FB_AFTER, T4_RETRY_S // 60)', '"Stick 1 Rückfall 10C (Lokal Nürnberg): 5C ohne Sync nach %d Prüfungen, 5C-Versuch alle %d min" % (T4_FB_AFTER, T4_RETRY_S // 60)', 1), ('"Stick 2 zurück auf 5C: 5C wieder mit Sync (Rückfall 10C beendet)"', '"Stick 1 zurück auf 5C: 5C wieder mit Sync (Rückfall 10C beendet)"', 1), ('"Stick 2 Rückfall 10C beendet (Übernahme aus)"', '"Stick 1 Rückfall 10C beendet"', 1)]


def sha256(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def stand(data):
    return sha256(data), len(data)


def berlin_jetzt():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin"))
    return datetime.now()


def berlin_minute():
    return berlin_jetzt().minute


def im_fenster(minute):
    return 5 <= int(minute) <= 39


def anker_ok(c, n):
    if isinstance(n, (tuple, list, set)):
        return c in n
    return c == n


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if not anker_ok(c, n):
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    ordner = os.path.dirname(pfad) or "."
    name = os.path.basename(pfad) + ".bak-" + KENNUNG + "-"
    alte = sorted(p for p in os.listdir(ordner) if p.startswith(name))
    for p in alte[:-3]:
        try:
            os.remove(os.path.join(ordner, p))
        except OSError:
            pass
    return ziel


def schreibe(pfad, daten):
    """Atomic ersetzen, Modus und Besitzer (uid/gid) der Originaldatei behalten."""
    st = os.stat(pfad) if os.path.exists(pfad) else None
    tmp = pfad + ".%s-tmp" % KENNUNG
    with open(tmp, "wb") as handle:
        handle.write(daten)
        handle.flush()
        os.fsync(handle.fileno())
    if st is not None:
        shutil.copymode(pfad, tmp)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except OSError:
            pass
    os.replace(tmp, pfad)
    if st is not None:
        try:
            os.chown(pfad, st.st_uid, st.st_gid)
            os.chmod(pfad, stat.S_IMODE(st.st_mode))
        except OSError as exc:
            print("Hinweis: Besitzer/Modus %s nicht gesetzt (%s)" % (pfad, exc))


def pyflakes_datei(pfad):
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except OSError:
            continue
        if r.returncode == 0 and not (r.stdout or "").strip() and not (r.stderr or "").strip():
            print("pyflakes %s ok" % os.path.basename(pfad))
            return True
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        print("pyflakes %s:\n%s" % (os.path.basename(pfad), err.strip()[:800]))
        return False
    print("Hinweis: pyflakes nicht installiert, nur py_compile")
    return True


def schon_sdr(text):
    return (
        "T5C_TRY_S = 90" in text
        and "kein Planner.lock" in text
        and "def _ff7b_note(" in text
        and "Stick 1 zurück auf 5C: 5C wieder mit Sync" in text
        and "return a is not None and a.get(\"role\") != \"5C\"" in text
        and "return not (a and a.get(\"role\") == \"5C\")" not in text
    )


def schon_dash(text):
    return (
        "def _los_lage(" in text
        and "SDR_OFFLINE nicht in der Lage" in text
        and "sdr_hint" in text
        and 'assert lv["lvl"] == "ok" and not lv["blink"] and lv.get("label") == "OK"' in text
    )


def patch_sdr_acars(text):
    """Korrigierter 5C-Fix auf Basis 86da726a (ohne Deadlock, _sf_skip unveraendert)."""
    paare = [
        (SDR_FF7B_ALT, SDR_FF7B_NEU, 1),
        (SDR_SUB_ALT, SDR_SUB_NEU, 1),
        (SDR_WATCHIF_ALT, SDR_WATCHIF_NEU, 1),
        (SDR_WATCH_ALT, SDR_WATCH_NEU, 1),
    ]
    paare.extend(SDR_MSG)
    for alt, neu, n in paare:
        text = ersetze(text, alt, neu, "prepper_sdr.py", n)
    return text


def patch_sdr_atis(text):
    """Hotfix des Deadlocks + _sf_skip-Ruecknahme auf f2cfa954. Gleicher Endstand."""
    text = ersetze(text, NOTE_LOCK_ALT, NOTE_LOCK_NEU, "prepper_sdr.py _ff7b_note", 1)
    text = ersetze(text, SKIP_BAD, SKIP_OK, "prepper_sdr.py _sf_skip", 1)
    return text


def patch_dash(text):
    text = ersetze(text, DASH_INSERT_BEFORE, LOS_FUNCS + DASH_INSERT_BEFORE, "dashboard.py helpers", 1)
    text = ersetze(text, DASH_LVL_ALT, DASH_LVL_NEU, "dashboard.py lage", 1)
    text = ersetze(text, DASH_RET_ALT, DASH_RET_NEU, "dashboard.py hint", 1)
    text = ersetze(text, DASH_ST_ALT, DASH_ST_NEU, "dashboard.py selftest", 1)
    text = ersetze(text, DASH_JS_ALT, DASH_JS_NEU, "dashboard.py js", 1)
    return text


def berechne_sdr(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        if hashcheck:
            return None, None, "STOP %s fehlt" % pfad
        return None, None, None
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == SDR_END_SHA and n == SDR_END_BYTES:
        return alt, None, None
    text = alt.decode("utf-8")
    if schon_sdr(text):
        return alt, None, None
    if hashcheck:
        ok = (
            (ist == SDR_START_ACARS and n == SDR_START_ACARS_B)
            or (ist == SDR_START_ATIS and n == SDR_START_ATIS_B)
        )
        if not ok:
            return None, None, "STOP prepper_sdr.py Hash %s/%d, erwartet %s/%d (bak-atis) oder %s/%d (apply-atis) oder Endstand %s/%d" % (
                ist[:16], n, SDR_START_ACARS16, SDR_START_ACARS_B,
                SDR_START_ATIS16, SDR_START_ATIS_B, SDR_END_SHA16, SDR_END_BYTES)
    if ist == SDR_START_ATIS or (not hashcheck and "sbc.last_saved = 0" in text and "def _ff7b_note(" in text and NOTE_LOCK_ALT in text):
        neu = patch_sdr_atis(text)
    else:
        neu = patch_sdr_acars(text)
    data = neu.encode("utf-8")
    hs, ns = stand(data)
    if hashcheck and (hs != SDR_END_SHA or ns != SDR_END_BYTES):
        return None, None, "STOP prepper_sdr.py Endhash %s/%d, erwartet %s/%d" % (hs[:16], ns, SDR_END_SHA16, SDR_END_BYTES)
    if not schon_sdr(neu):
        return None, None, "STOP prepper_sdr.py Markierungen nach Patch unvollstaendig"
    return alt, data, None


def berechne_dash(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        if hashcheck:
            return None, None, "STOP %s fehlt" % pfad
        return None, None, None
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == DASH_END_SHA and n == DASH_END_BYTES:
        return alt, None, None
    text = alt.decode("utf-8")
    if schon_dash(text):
        return alt, None, None
    if hashcheck and not (ist == DASH_START_SHA and n == DASH_START_BYTES):
        return None, None, "STOP dashboard.py Hash %s/%d, erwartet %s/%d oder Endstand %s/%d" % (
            ist[:16], n, DASH_START_SHA16, DASH_START_BYTES, DASH_END_SHA16, DASH_END_BYTES)
    neu = patch_dash(text)
    data = neu.encode("utf-8")
    hs, ns = stand(data)
    if hashcheck and (hs != DASH_END_SHA or ns != DASH_END_BYTES):
        return None, None, "STOP dashboard.py Endhash %s/%d, erwartet %s/%d" % (hs[:16], ns, DASH_END_SHA16, DASH_END_BYTES)
    if not schon_dash(neu):
        return None, None, "STOP dashboard.py Markierungen nach Patch unvollstaendig"
    return alt, data, None


def hinweis_basis(root):
    for name, sha16, nbytes in (
        ("acars_kachel.py", KACHEL_SHA16, KACHEL_BYTES),
        ("eddn_atis.py", EDDN_SHA16, EDDN_BYTES),
        ("flugfunk.py", FF_SHA16, FF_BYTES),
    ):
        p = os.path.join(root, name)
        if not os.path.isfile(p):
            print("Hinweis: %s fehlt (wird nicht geaendert)" % name)
            continue
        raw = open(p, "rb").read()
        print("Hinweis %s sha16 %s bytes %d%s" % (
            name, sha256(raw)[:16], len(raw),
            "" if sha256(raw).startswith(sha16) and len(raw) == nbytes else " (abweichend, unangetastet)"))


def _unit_snap(dienst):
    snap = {"pid": "", "ts": "", "active": ""}
    try:
        r = subprocess.run(
            ["systemctl", "show", dienst, "-p", "MainPID", "-p", "ActiveEnterTimestamp", "-p", "ActiveState"],
            capture_output=True, text=True, timeout=8)
        for ln in (r.stdout or "").splitlines():
            if "=" not in ln:
                continue
            k, v = ln.split("=", 1)
            if k == "MainPID":
                snap["pid"] = v.strip()
            elif k == "ActiveEnterTimestamp":
                snap["ts"] = v.strip()
            elif k == "ActiveState":
                snap["active"] = v.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return snap


def _restart_ok(rc, before, after):
    if rc != 0:
        return False
    if after.get("active") in ("failed", "inactive", "deactivating"):
        return False
    if before.get("pid") and after.get("pid") and before["pid"] != "0" and after["pid"] == before["pid"]:
        if before.get("ts") and after.get("ts") and before["ts"] == after["ts"]:
            return False
    if after.get("active") in ("active", "activating", "reloading"):
        return True
    if not after.get("active") and not before.get("active") and rc == 0:
        return True
    return after.get("active") == "active"


def _run_restart(cmd):
    try:
        rc = subprocess.call(cmd)
    except OSError:
        return 127
    return rc


def restart_dienst(dienst):
    before = _unit_snap(dienst)
    rc = _run_restart(["systemctl", "restart", dienst])
    after = _unit_snap(dienst)
    if _restart_ok(rc, before, after):
        print("restart %s rc %s" % (dienst, rc))
        return 0
    rc2 = _run_restart(["sudo", "systemctl", "restart", dienst])
    after = _unit_snap(dienst)
    if _restart_ok(rc2, before, after):
        print("restart %s rc %s (sudo)" % (dienst, rc2))
        return 0
    gesehen = rc2 if rc2 != 0 else rc
    print("STOP Neustart fehlgeschlagen – bitte sudo systemctl restart %s" % dienst)
    print("systemctl rc %s, Zustand %s PID %s -> %s" % (
        gesehen, after.get("active") or "?", before.get("pid") or "-", after.get("pid") or "-"))
    return gesehen if gesehen != 0 else 1


def neustart(dienste):
    rc_all = 0
    for dienst in dienste:
        rc = restart_dienst(dienst)
        if rc != 0:
            rc_all = rc
    return rc_all


def warte_http(urls, timeout=45):
    t0 = time.time()
    offen = list(urls)
    letzte = {}
    while offen and (time.time() - t0) < timeout:
        noch = []
        for url, ziel in offen:
            try:
                r = subprocess.run(
                    ["curl", "-sS", "-m", "5", "-o", ziel, "-w", "%{http_code}", url],
                    capture_output=True, text=True, timeout=8)
                code = (r.stdout or "").strip()
                letzte[url] = code
                if r.returncode == 0 and code.startswith("200"):
                    print("GET %s -> 200 nach %.1f s" % (url, time.time() - t0))
                    continue
            except (OSError, subprocess.TimeoutExpired) as exc:
                letzte[url] = type(exc).__name__
            noch.append((url, ziel))
        offen = noch
        if offen:
            time.sleep(2)
    ok = True
    for url, ziel in offen:
        print("STOP %s nicht 200 innerhalb %s s (zuletzt %s)" % (url, timeout, letzte.get(url)))
        ok = False
    return ok


def journal_pruefen(seit, dienste, pause=0):
    if pause:
        print("warte %s s auf Journal" % pause)
        time.sleep(pause)
    ok = True
    urls = [
        ("http://127.0.0.1:5000/", "/tmp/apply-lageohnesdr-lage.html"),
        ("http://127.0.0.1:5000/funk", "/tmp/apply-lageohnesdr-funk.html"),
    ]
    if DIENSTE_DASH in dienste or not dienste:
        if not warte_http(urls, timeout=45):
            ok = False
    for dienst in dienste:
        try:
            r = subprocess.run(
                ["journalctl", "-u", dienst, "--since", seit, "-o", "cat", "-n", "80"],
                capture_output=True, text=True, timeout=10)
            zeilen = (r.stdout or "").splitlines()
        except (OSError, subprocess.TimeoutExpired):
            print("Hinweis: Journal %s unlesbar" % dienst)
            continue
        if any("Traceback" in ln for ln in zeilen):
            print("STOP Journal %s enthaelt Traceback" % dienst)
            for ln in [x for x in zeilen if "Traceback" in x][:8]:
                print(ln)
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (dienst, len(zeilen)))
    html_l = "/tmp/apply-lageohnesdr-lage.html"
    if os.path.isfile(html_l):
        html = open(html_l, encoding="utf-8", errors="replace").read()
        if html and "t4-offline" in html and "t4-blink" in html and "SDR_OFFLINE" in html:
            print("STOP Lage-Seite blinkt noch mit SDR_OFFLINE")
            ok = False
        elif html:
            print("Lage-Seite geladen (kein t4-offline+t4-blink mit SDR_OFFLINE)")
    return ok


def anwenden(root, dry, kein, minute, hashcheck=True, pause=0):
    sdr = os.path.join(root, "prepper_sdr.py")
    dash = os.path.join(root, "dashboard.py")
    hinweis_basis(root)
    paare = []
    dienste = []
    for name, fn, berechne, dienst in (
        ("prepper_sdr.py", sdr, berechne_sdr, DIENSTE_SDR),
        ("dashboard.py", dash, berechne_dash, DIENSTE_DASH),
    ):
        alt, neu, err = berechne(fn, hashcheck=hashcheck)
        if err:
            print(err)
            return 2
        if neu is None:
            print("%s bereits auf Endstand, unveraendert" % name)
            continue
        paare.append((fn, alt, neu, name))
        if dienst not in dienste:
            dienste.append(dienst)
    if not paare:
        print("nichts zu tun")
        return 0
    if dry:
        for fn, alt, neu, name in paare:
            print("dry-run %s %d -> %d Bytes sha256 %s" % (name, len(alt), len(neu), sha256(neu)))
        print("dry-run: keine Datei geschrieben, kein Neustart (waeren: %s)" % ", ".join(dienste))
        return 0
    if not kein and not im_fenster(minute):
        print("STOP ausserhalb Fenster 05-39 (Berlin, jetzt Minute %02d) – mit --kein-neustart oder spaeter" % minute)
        return 3
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    for fn, alt, neu, name in paare:
        bak = sichern(fn, stempel)
        print("Backup %s" % bak)
        schreibe(fn, neu)
        hs, ns = stand(open(fn, "rb").read())
        print("geschrieben %s sha256 %s bytes %d" % (name, hs, ns))
        try:
            st = os.stat(fn)
            print("Besitzer %s uid %s gid %s mode %04o" % (name, st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode)))
        except OSError:
            pass
        compile(neu, name, "exec")
        if not pyflakes_datei(fn):
            print("STOP pyflakes %s" % name)
            return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = neustart(dienste)
    if rc != 0:
        return rc
    if not journal_pruefen(seit, dienste, pause=pause):
        return 5
    print("ok, Dienste: %s" % ", ".join(dienste))
    return 0


def _selftest_lage_helfer():
    ns = {"_T4": {"fake": {"live": "SDR_OFFLINE"}}}
    exec(LOS_FUNCS, ns)
    lage = ns["_los_lage"]
    lv = lage({"lvl": "offline", "label": "SDR_OFFLINE", "blink": True, "color": "#f97316",
               "why": "SDR_OFFLINE: keine frische Telemetrie von prepper-sdr (Watchdog 15 s)"}, "SDR_OFFLINE", 1)
    assert lv["lvl"] == "ok" and not lv["blink"] and lv["label"] == "OK", lv
    lv = lage({"lvl": "alarm", "label": "ECHTALARM", "blink": True, "color": "#ef4444", "why": "ASA: x"}, "SDR_OFFLINE", 1)
    assert lv["lvl"] == "alarm" and lv["blink"]
    lv = lage({"lvl": "offline", "label": "SDR_OFFLINE", "blink": True, "color": "#f97316",
               "why": "SDR_OFFLINE: x · VORALARM NETZ: y"}, "SDR_OFFLINE", 1)
    assert lv["lvl"] == "pre" and "VORALARM" in lv["label"], lv
    lv = lage({"lvl": "probe", "label": "PROBEALARM", "blink": False, "color": "#eab308", "why": "ASA DE: Probe"}, "OK", 1)
    assert lv["lvl"] == "probe"
    h, live = ns["_los_hint"]("SDR_OFFLINE", 1)
    assert live == "SDR_OFFLINE" and "Telemetrie" in h and "nicht die Lage" in h, (h, live)
    h2, live2 = ns["_los_hint"]("OK", 1)
    assert h2 is None and live2 == "OK"
    ns["_T4"]["fake"] = {}
    ns["_T4"]["_los_age"] = (time.time(), 30.0)
    h3, live3 = ns["_los_hint"]("SDR_OFFLINE", time.time())
    assert live3 == "STARTING" and "Karenz" in (h3 or ""), (h3, live3)
    print("selftest Lage-Helfer ok")


def _selftest_telemetrie_takt(sdr_text):
    """_ff7b_note unter gehaltenem Planner.lock darf nicht blockieren, Takt schreibt weiter."""
    a = sdr_text.find("def _ff7b_ch(")
    b = sdr_text.find("def _ff7b_bc_queue(")
    if a < 0 or b < 0:
        raise SystemExit("selftest note-Block fehlt")
    fn = (
        "import time\nT4_RETRY_S = 600\nT5C_TRY_S = 90\n"
        "def _ff7b_fresh(*a, **k):\n    return False\n"
        + sdr_text[a:b]
    )
    note = sdr_text[sdr_text.find("def _ff7b_note("):b]
    if "with self.lock:" in note:
        raise SystemExit("selftest _ff7b_note enthaelt noch with self.lock:")
    ns = {}
    exec(fn, ns)

    class Sbc(object):
        def __init__(self):
            self.d = {"dab": {}}
            self.dirty = False
            self.last_saved = 1

    class Pl(object):
        def __init__(self):
            self.lock = threading.Lock()
            self.sbc = Sbc()
            self.active = "dab:0"

    pl = Pl()
    if not pl.lock.acquire(False):
        raise SystemExit("selftest Lock")
    hung = []
    done = [False]

    def waechter():
        time.sleep(1.5)
        if not done[0]:
            hung.append(1)

    th = threading.Thread(target=waechter)
    th.daemon = True
    th.start()
    t0 = time.time()
    ns["_ff7b_note"](pl, t0)
    done[0] = True
    dt = time.time() - t0
    pl.lock.release()
    if hung or dt >= 1.0:
        raise SystemExit("selftest DEADLOCK _ff7b_note unter self.lock (%.3f s)" % dt)
    if not pl.sbc.dirty or "fb5c" not in pl.sbc.d:
        raise SystemExit("selftest fb5c nicht geschrieben")
    tmp = tempfile.mkdtemp(prefix="lageohnesdr-tel-")
    path = os.path.join(tmp, "sdr_status.json")
    times = []
    for i in range(5):
        now = t0 + i * 2
        with pl.lock:
            ns["_ff7b_note"](pl, now)
            rec = {"t": int(now), "pid": 4242, "i": i, "active": "dab:0"}
            raw = (json.dumps(rec) + "\n").encode("utf-8")
            tmpf = path + ".tmp"
            with open(tmpf, "wb") as fh:
                fh.write(raw)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmpf, path)
            times.append(rec["t"])
    last = json.loads(open(path, encoding="utf-8").read())
    if last.get("i") != 4 or last.get("t") != times[-1] or times != sorted(times):
        raise SystemExit("selftest Telemetrie-Takt %s" % last)
    alter = times[-1] - times[0]
    if alter != 8:
        raise SystemExit("selftest Takt-Abstand %s" % times)
    print("selftest Telemetrie-Takt ok (5 Schreibvorgaenge unter Lock, %.4f s/note, Alter %d s)" % (dt, alter))


def _selftest_restart_check():
    assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "Mon 2026-01-01", "active": "active"},
                       {"pid": "10", "ts": "Mon 2026-01-01", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"},
                       {"pid": "11", "ts": "B", "active": "active"}) is True
    print("selftest Neustart-Check ok")


def selftest():
    _selftest_lage_helfer()
    _selftest_restart_check()
    assert im_fenster(5) and im_fenster(39) and not im_fenster(4) and not im_fenster(40)
    root = tempfile.mkdtemp(prefix="lageohnesdr-st-")
    rc = anwenden(root, True, False, 10, hashcheck=True)
    if rc != 2:
        raise SystemExit("selftest fehlende Datei rc %s" % rc)
    acars = "/tmp/prepper_sdr_acars.py"
    dash = "/tmp/dashboard_atis.py"
    if os.path.isfile(acars) and os.path.isfile(dash):
        src_s = open(acars, "rb").read()
        src_d = open(dash, "rb").read()
        if sha256(src_s) != SDR_START_ACARS:
            raise SystemExit("selftest Vorlage acars %s" % sha256(src_s)[:16])
        if sha256(src_d) != DASH_START_SHA:
            raise SystemExit("selftest Vorlage dash %s" % sha256(src_d)[:16])
        neu_s = patch_sdr_acars(src_s.decode("utf-8")).encode("utf-8")
        neu_d = patch_dash(src_d.decode("utf-8")).encode("utf-8")
        if sha256(neu_s) != SDR_END_SHA or len(neu_s) != SDR_END_BYTES:
            raise SystemExit("selftest sdr Endhash %s/%d" % (sha256(neu_s), len(neu_s)))
        if sha256(neu_d) != DASH_END_SHA or len(neu_d) != DASH_END_BYTES:
            raise SystemExit("selftest dash Endhash %s/%d" % (sha256(neu_d), len(neu_d)))
        compile(neu_s, "prepper_sdr.py", "exec")
        compile(neu_d, "dashboard.py", "exec")
        if not schon_sdr(neu_s.decode("utf-8")) or not schon_dash(neu_d.decode("utf-8")):
            raise SystemExit("selftest Markierungen")
        _selftest_telemetrie_takt(neu_s.decode("utf-8"))
        atis_path = "/workspace/apply-atis.py"
        if os.path.isfile(atis_path):
            import importlib.util
            spec = importlib.util.spec_from_file_location("_atis_lage", atis_path)
            atis = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(atis)
            atis_s = atis.patch_sdr(src_s.decode("utf-8")).encode("utf-8")
            if sha256(atis_s) != SDR_START_ATIS:
                print("Hinweis: apply-atis liefert nicht f2cfa954 (%s), Hotfix-Pfad trotzdem geprueft" % sha256(atis_s)[:16])
            hot = patch_sdr_atis(atis_s.decode("utf-8")).encode("utf-8")
            if sha256(hot) != SDR_END_SHA or hot != neu_s:
                raise SystemExit("selftest Hotfix-Endstand weicht ab %s/%d" % (sha256(hot), len(hot)))
            print("selftest beide prepper_sdr-Startstaende -> gleicher Endstand %s/%d" % (SDR_END_SHA16, SDR_END_BYTES))
        os.makedirs(root, exist_ok=True)
        p1 = os.path.join(root, "prepper_sdr.py")
        p2 = os.path.join(root, "dashboard.py")
        open(p1, "wb").write(src_s)
        open(p2, "wb").write(src_d)
        os.chmod(p1, 0o644)
        os.chmod(p2, 0o644)
        rc = anwenden(root, True, False, 10, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest dry-run rc %s" % rc)
        if open(p1, "rb").read() != src_s or open(p2, "rb").read() != src_d:
            raise SystemExit("selftest dry-run hat geschrieben")
        rc = anwenden(root, False, False, 0, hashcheck=True)
        if rc != 3:
            raise SystemExit("selftest Fenster rc %s" % rc)
        rc = anwenden(root, False, True, 0, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest kein-neustart rc %s" % rc)
        if sha256(open(p1, "rb").read()) != SDR_END_SHA or sha256(open(p2, "rb").read()) != DASH_END_SHA:
            raise SystemExit("selftest geschrieben falsch")
        st1 = os.stat(p1)
        if stat.S_IMODE(st1.st_mode) != 0o644:
            raise SystemExit("selftest mode %04o" % stat.S_IMODE(st1.st_mode))
        rc = anwenden(root, False, True, 10, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest idempotent rc %s" % rc)
        if not pyflakes_datei(p1) or not pyflakes_datei(p2):
            raise SystemExit("selftest pyflakes")
        print("selftest apply auf Vorlagen ok")
    else:
        print("Hinweis: /tmp-Vorlagen fehlen, Hash-Pfad nur teilweise geprueft")
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    parser.add_argument("--fullcheck", default="", help="wird nicht geaendert")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    return anwenden(args.basis, args.dry_run, args.kein_neustart, berlin_minute())


if __name__ == "__main__":
    raise SystemExit(main())
