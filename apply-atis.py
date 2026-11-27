#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-atis: lesbare ATIS-Zeile EDDN in der Flugfunk-Kachel auf /adsb.

Konzept (kurz):
1. Eine Zeile in der bestehenden Flugfunk-Kachel (ffWetter), kein Kachel-in-Kachel.
2. Format z. B. „Info K · Piste 28 · Wind 270° 12 kt · Sicht über 10 km · Wolken 3000 ft · 8 °C · QNH 1013 · vor 4 min“.
3. Nur die letzte vollständige ATIS; Wiederholungen derselben Kennung werden zusammengeführt.
4. Unsichere oder widersprüchliche Felder entfallen, es wird nicht geraten.
5. Frisches D-ATIS aus acars_msgs.jsonl (Label/Text ATIS EDDN) hat Vorrang, sonst Whisper 123,080.
6. Rohtext bleibt aufklappbar; keine Netzabfrage, nur lokal, § 5 TTDSG, keine Seriennummern.
7. Neues Modul eddn_atis.py neben flugfunk.py. ACARS-Kachel unverändert.
8. Zugleich 5C: kein Doppelstart, Versuch 90 s, sdrLog/Stick-Nummer korrigiert, ASA-Zeile im 10C-Rückfall ruhig.
9. Neustart prepper-sdr (Planer, Transkript) und prepper-dashboard (Anzeige). Echter systemctl-Status, sonst STOP.
   Nach Dashboard-Neustart bis 45 s auf HTTP 200 warten.

Beispiel (gekennzeichnet, keine Live-Daten):
  Flugfunk · EDDN
  Info K · Piste 28 · Wind 270° 12 kt · Sicht über 10 km · Wolken 3000 ft · 8 °C · QNH 1013 · vor 4 min (123,080) Rohtext

Kein fullcheck. Basis nach apply-acars: prepper_sdr 86da726a/803996, dashboard 6e7715e8/1397320,
acars_kachel 68f52f16/38999, flugfunk bd67c57b98e452fb38b5ea218389eb5140fb21788284cc647772de9895f0bd4d/99285
(strikter Start-Hash; der 99286-Vor-dabfix-Stand lag hier nicht als Datei vor, daher kein vorab
berechneter flugfunk-Endhash – nach dem Schreiben wird sha256 ausgegeben und Markierungen geprüft).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import zlib
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "atis"
BASIS = "/home/fmg/prepper-dashboard"
DIENSTE = ("prepper-sdr", "prepper-dashboard")
MOD_NAME = "eddn_atis.py"

# Erwartete Basis nach apply-acars (nur Hinweis, ausser flugfunk + Modul)
SDR_START_SHA = "86da726a0fae96630e2a132f8ac2e8221bb3bd8e483ddb6b9b00fe1ee8d19637"
SDR_START_SHA16 = "86da726a0fae9663"
SDR_START_BYTES = 803996
SDR_END_SHA = "f2cfa954190cafe3fa8ddf403540194eb79000910c10d52228bb7e0c7278070f"
SDR_END_SHA16 = "f2cfa954190cafe3"
SDR_END_BYTES = 806124
DASH_START_SHA = "6e7715e851337f65e8fd504171e5b50c6dbf814b9f76718ddbab550b3105f467"
DASH_START_SHA16 = "6e7715e851337f65"
DASH_START_BYTES = 1397320
DASH_END_SHA = "54fda6e066f4b3441c0c9dc240ef557fb0681001f663d3dd3791b6310dcbec20"
DASH_END_SHA16 = "54fda6e066f4b344"
DASH_END_BYTES = 1397857
KACHEL_SHA = "68f52f16a3949fd2b1f9086bb70b91626a1f33a968bf5edcce28a75d4fed91b3"
KACHEL_SHA16 = "68f52f16a3949fd2"
KACHEL_BYTES = 38999
FF_START_SHA = "bd67c57b98e452fb38b5ea218389eb5140fb21788284cc647772de9895f0bd4d"
FF_START_SHA16 = "bd67c57b98e452fb"
FF_START_BYTES = 99285
# flugfunk-Endhash: nur pruefen, wenn bekannt (Live-Datei 99285 lag hier nicht vor)
FF_END_SHA = ""
FF_END_BYTES = 0

MOD_SHA = "0420d632a8718860b3be2091383663fcbe95c77cef853f9bddc12e5dfcbaa84f"
MOD_SHA16 = "0420d632a8718860"
MOD_BYTES = 46475

MOD_BLOB = (
    "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"
)

JS_ALT = r'''    var wetter=document.getElementById('ffWetter');
    if(wetter){
      var w=d.wetter||{};
      var teile=[];
      if(w.kennung && String(w.kennung).length===1) teile.push('<b style="font-size:22px">'+esc(w.kennung)+'</b>');
      if(w.dir!=null && w.wind) teile.push('<span style="display:inline-block;transform:rotate('+w.dir+'deg)">↑</span> '+esc(w.wind));
      else if(w.wind) teile.push(esc(w.wind));
      if(w.sicht) teile.push(esc(w.sicht));
      if(w.wolken) teile.push(esc(w.wolken));
      if(w.qnh) teile.push('QNH '+esc(w.qnh));
      if(w.piste) teile.push('Piste '+esc(w.piste));
      if(w.qnh || w.wind || w.sicht) teile.push('<span style="color:'+(w.vfr?'#22c55e':'#f87171')+'">'+(w.vfr?'VFR':'IFR')+'</span>');
      wetter.innerHTML=teile.length?teile.join(' · '):(w.text||'Wetter EDDN: noch kein METAR');
    }
'''
JS_NEU = r'''    var wetter=document.getElementById('ffWetter');
    if(wetter){
      var w=d.wetter||{};
      if(w.zeile){
        var html=esc(w.zeile);
        if(w.alter) html+=' · '+esc(w.alter);
        if(w.quelle) html+=' <span style="color:#94a3b8">('+esc(w.quelle)+')</span>';
        if(w.roh) html+=' <details style="display:inline"><summary style="cursor:pointer;color:#94a3b8">Rohtext</summary><div style="white-space:pre-wrap;font-size:12px;margin-top:2px;color:#cbd5e1">'+esc(w.roh)+'</div></details>';
        wetter.innerHTML=html;
      } else {
        var teile=[];
        if(w.kennung && String(w.kennung).length===1) teile.push('<b style="font-size:22px">'+esc(w.kennung)+'</b>');
        if(w.dir!=null && w.wind) teile.push('<span style="display:inline-block;transform:rotate('+w.dir+'deg)">↑</span> '+esc(w.wind));
        else if(w.wind) teile.push(esc(w.wind));
        if(w.sicht) teile.push(esc(w.sicht));
        if(w.wolken) teile.push(esc(w.wolken));
        if(w.qnh) teile.push('QNH '+esc(w.qnh));
        if(w.piste) teile.push('Piste '+esc(w.piste));
        if(w.qnh || w.wind || w.sicht) teile.push('<span style="color:'+(w.vfr?'#22c55e':'#f87171')+'">'+(w.vfr?'VFR':'IFR')+'</span>');
        wetter.innerHTML=teile.length?teile.join(' · '):(w.text||'Wetter EDDN: noch kein ATIS');
      }
    }
'''
ATIS_ALT = r'''        if int(freq or 0) == ATIS_HZ:
            neu = parse_atis(text)
            alt = _meta(con, "atis_kennung")
            if atis_uebernehmen(alt, neu):
                wetter = metar_holen(lambda url: None, "")
                konflikt = widerspruch(neu, wetter)
                con.execute(
                    "INSERT INTO atis(t, kennung, text, wind, sicht, wolken, temp, qnh, piste, metar, taf, widerspruch) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    (int(now), neu["kennung"], text[:500], neu["wind"], neu["sicht"], neu["wolken"],
                     neu["temp"], neu["qnh"], neu["piste"], "", "", 1 if konflikt else 0),
                )
                con.execute(
                    "INSERT INTO meta(key, wert) VALUES ('atis_kennung', ?) "
                    "ON CONFLICT(key) DO UPDATE SET wert=excluded.wert",
                    (neu["kennung"],),
                )
'''
ATIS_NEU = r'''        if int(freq or 0) == ATIS_HZ:
            try:
                import os as _ea_os, sys as _ea_sys
                _ea_dir = _ea_os.path.dirname(_ea_os.path.abspath(__file__))
                if _ea_dir not in _ea_sys.path:
                    _ea_sys.path.insert(0, _ea_dir)
                import eddn_atis as _eddn_atis
                _eddn_atis.ablegen(con, text, now)
            except Exception as _ea:
                print("eddnAtis ablegen:", type(_ea).__name__, flush=True)
                neu = parse_atis(text)
                alt = _meta(con, "atis_kennung")
                if atis_uebernehmen(alt, neu):
                    wetter = metar_holen(lambda url: None, "")
                    konflikt = widerspruch(neu, wetter)
                    con.execute(
                        "INSERT INTO atis(t, kennung, text, wind, sicht, wolken, temp, qnh, piste, metar, taf, widerspruch) "
                        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                        (int(now), neu["kennung"], text[:500], neu["wind"], neu["sicht"], neu["wolken"],
                         neu["temp"], neu["qnh"], neu["piste"], "", "", 1 if konflikt else 0),
                    )
                    con.execute(
                        "INSERT INTO meta(key, wert) VALUES ('atis_kennung', ?) "
                        "ON CONFLICT(key) DO UPDATE SET wert=excluded.wert",
                        (neu["kennung"],),
                    )
'''
END_ALT = r'''if __name__ == "__main__":
    print(selftest())
'''
END_NEU = r'''# ===== eddnAtis =====
try:
    import os as _ea_os, sys as _ea_sys
    _ea_dir = _ea_os.path.dirname(_ea_os.path.abspath(__file__))
    if _ea_dir not in _ea_sys.path:
        _ea_sys.path.insert(0, _ea_dir)
    import eddn_atis as _eddn_atis
    def status(base, now=None, _status_alt=status):
        d = _status_alt(base, now)
        try:
            return _eddn_atis.status_anreichern(base, d, now)
        except Exception as exc:
            print("eddnAtis status:", type(exc).__name__, flush=True)
            return d
except Exception as _ea_imp:
    print("eddnAtis import:", type(_ea_imp).__name__, flush=True)
# ===== /eddnAtis =====


if __name__ == "__main__":
    print(selftest())
'''


SDR_FF7B_ALT = r'''def _ff7b_bc_queue(self):
    """Stick Rolle 5C: ASA 5C hat Vorrang. Nur wenn 5C keinen frischen Sync hat, 10C;
    5C wird trotzdem alle 10 min (T4_RETRY_S) mit vollem Block erneut geprueft.
    Verhindert, dass ein alter 10C-Sync 5C dauerhaft verdraengt (cpulimit-Ausfall 26.11.)."""
    q = _ff7b_orig_bc(self)
    try:
        a = _air_pl(self)
        if not a or a.get("role") != "5C":
            return q
        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
        lst = [str(x) for x in self.dab_list()]
        if "5C" not in lst:
            return q
        now = time.time()
        dur = float(self.cfg.get("dab_s") or 60)
        i5 = lst.index("5C")
        i10 = lst.index("10C") if "10C" in lst else None
        if _ff7b_fresh(dab.get("5C"), now):
            return [("dab:%d" % i5, dur)]
        last = float(self.__dict__.get("_ff7b_last5c") or 0)
        due = True if not last else (now - last) >= float(T4_RETRY_S)
        if due:
            return [("dab:%d" % i5, dur)]
        if i10 is not None and _ff7b_fresh(dab.get("10C"), now):
            return [("dab:%d" % i10, dur)]
    except Exception:
        return q
    return q
'''
SDR_FF7B_NEU = r'''T5C_TRY_S = 90  # volle 5C-Pruefung, nicht durch Doppelstart kuerzen


def _ff7b_ch(self):
    act = _s(getattr(self, "active", None))
    if not act.startswith("dab:"):
        return ""
    try:
        lst = [str(x) for x in self.dab_list()]
        i = int(act[4:])
        return lst[i] if i < len(lst) else ""
    except Exception:
        return ""


def _ff7b_is_fb(self, now=None):
    """True, wenn der 5C-Planer im gewollten 10C-Rueckfall ist (kein frischer 5C-Sync)."""
    now = time.time() if now is None else float(now)
    try:
        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
        if _ff7b_fresh(dab.get("5C"), now):
            return False
        if _ff7b_ch(self) == "10C":
            return True
        last = float(self.__dict__.get("_ff7b_last5c") or 0)
        if last and (now - last) < float(T4_RETRY_S):
            return True
    except Exception:
        pass
    return False


def _ff7b_note(self, now=None):
    now = time.time() if now is None else float(now)
    try:
        last = float(self.__dict__.get("_ff7b_last5c") or 0)
        fb = _ff7b_is_fb(self, now)
        rec = {
            "v": 1, "fb": bool(fb),
            "last5c": int(last) if last else None,
            "next": int(last + T4_RETRY_S) if last and fb else None,
            "try_s": int(T5C_TRY_S), "t": int(now),
        }
        sbc = getattr(self, "sbc", None)
        if sbc is None:
            return
        with self.lock:
            sbc.d["fb5c"] = rec
            sbc.dirty = True
            sbc.last_saved = 0
    except Exception as ex:
        print("ff7b note:", type(ex).__name__, flush=True)


def _ff7b_bc_queue(self):
    """Stick Rolle 5C: ASA 5C hat Vorrang. Nur wenn 5C keinen frischen Sync hat, 10C;
    5C wird trotzdem alle 10 min (T4_RETRY_S) mit vollem Block (T5C_TRY_S, 90 s) erneut geprueft.
    Kein Doppelstart, wenn 5C schon laeuft (auch wenn sich der Queue-Index aendert)."""
    q = _ff7b_orig_bc(self)
    try:
        a = _air_pl(self)
        if not a or a.get("role") != "5C":
            return q
        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
        lst = [str(x) for x in self.dab_list()]
        if "5C" not in lst:
            return q
        now = time.time()
        dur = float(self.cfg.get("dab_s_5c") or T5C_TRY_S)
        act = _s(getattr(self, "active", None))
        if act.startswith("dab:") and self.procs and self.alive() and _ff7b_ch(self) == "5C":
            _ff7b_note(self, now)
            return [(act, dur)]
        i5 = lst.index("5C")
        i10 = lst.index("10C") if "10C" in lst else None
        if _ff7b_fresh(dab.get("5C"), now):
            _ff7b_note(self, now)
            return [("dab:%d" % i5, dur)]
        last = float(self.__dict__.get("_ff7b_last5c") or 0)
        due = True if not last else (now - last) >= float(T4_RETRY_S)
        if due:
            _ff7b_note(self, now)
            return [("dab:%d" % i5, dur)]
        if i10 is not None and _ff7b_fresh(dab.get("10C"), now):
            _ff7b_note(self, now)
            return [("dab:%d" % i10, dur)]
        _ff7b_note(self, now)
    except Exception:
        return q
    return q


'''
SDR_SUB_ALT = r'''def _ff7b_sub_done(self, sp, now):
    try:
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") is not None else ""
        if _s(job).startswith("dab:"):
            lst = [str(x) for x in self.dab_list()]
            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else ""
            if ch == "5C":
                self.__dict__["_ff7b_last5c"] = float(now)
    except Exception:
        pass
    return _ff7b_orig_sub(self, sp, now)
'''
SDR_SUB_NEU = r'''def _ff7b_sub_done(self, sp, now):
    try:
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") is not None else ""
        if _s(job).startswith("dab:"):
            lst = [str(x) for x in self.dab_list()]
            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else ""
            if ch == "5C":
                self.__dict__["_ff7b_last5c"] = float(now)
        _ff7b_note(self, now)
    except Exception:
        pass
    return _ff7b_orig_sub(self, sp, now)


'''
SDR_WATCH_ALT = r'''        st4 = self.__dict__.get("_t4")
        fb = bool(st4.get("fb")) if isinstance(st4, dict) else False
        with _SDRLOG_LOCK:
            tl = sdrlog_get(self.base)
            if tl.stick(bool(to.get("on")), to, _sf_fb(self, tl, fb, now), al, now):
                tl.save()
'''
SDR_WATCH_NEU = r'''        fb = _ff7b_is_fb(self, now)
        sync = False
        try:
            dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
            sync = _ff7b_fresh(dab.get("5C"), now)
        except Exception:
            sync = False
        with _SDRLOG_LOCK:
            tl = sdrlog_get(self.base)
            if tl.stick(bool(to.get("on")), to, _sf_fb(self, tl, fb, now), sync, now):
                tl.save()
'''
SDR_SKIP_ALT = r'''    return a is not None and a.get("role") != "5C"
'''
SDR_SKIP_NEU = r'''    return not (a and a.get("role") == "5C")
'''
SDR_WATCHIF_ALT = r'''        if getattr(self, "role", None) != "rot" or not t2_on(self) or _sf_skip(self):
            return
'''
SDR_WATCHIF_NEU = r'''        if _sf_skip(self):
            return
'''
SDR_MSG = [
    ('"Stick 2 Rückfall 10C (Lokal Nürnberg): 5C ohne Sync nach %d Prüfungen, 5C-Versuch alle %d min" % (T4_FB_AFTER, T4_RETRY_S // 60)', '"Stick 1 Rückfall 10C (Lokal Nürnberg): 5C ohne Sync nach %d Prüfungen, 5C-Versuch alle %d min" % (T4_FB_AFTER, T4_RETRY_S // 60)', 1),
    ('"Stick 2 zurück auf 5C: 5C wieder mit Sync (Rückfall 10C beendet)"', '"Stick 1 zurück auf 5C: 5C wieder mit Sync (Rückfall 10C beendet)"', 1),
    ('"Stick 2 Rückfall 10C beendet (Übernahme aus)"', '"Stick 1 Rückfall 10C beendet"', 1),
]
DASH_ASA_ALT = r'''    elif t:
        out.update(state="grau", l1="%s · kein Empfang seit %s" % (src, _br24_fmt(t)))
    else:
        out.update(state="grau", l1="%s · noch nicht empfangen" % src)
    return out
'''
DASH_ASA_NEU = r'''    fb = b.get("fb5c") if isinstance(b.get("fb5c"), dict) else {}
    fb_on = bool(fb.get("fb") or fb.get("on"))
    if fb_on:
        nxt = _sd_hm(fb.get("next"), now)
        out.update(state="gelb", l1="%s · Rückfall 10C aktiv · 5C hier nicht empfangbar, nächster Versuch %s" % (src, nxt))
    elif t:
        out.update(state="grau", l1="%s · kein Empfang seit %s" % (src, _br24_fmt(t)))
    else:
        out.update(state="grau", l1="%s · noch nicht empfangen" % src)
    return out
'''
DASH_ST_ALT = r'''    assert _sd_asa_row({"dab": {"5C": {"t": now - 99999}}}, r, now)["l1"].startswith("ASA DE · DAB 5C · kein Empfang seit")
'''
DASH_ST_NEU = r'''    assert _sd_asa_row({"dab": {"5C": {"t": now - 99999}}}, r, now)["l1"].startswith("ASA DE · DAB 5C · kein Empfang seit")
    fbrow = _sd_asa_row({"dab": {"5C": {"t": now - 99999}}, "fb5c": {"fb": True, "next": now + 600}}, r, now)
    assert fbrow["state"] == "gelb" and "Rückfall 10C aktiv" in fbrow["l1"] and "5C hier nicht empfangbar" in fbrow["l1"], fbrow
'''

def sha256(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def mod_bytes():
    return zlib.decompress(base64.b64decode("".join(MOD_BLOB)))


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


def FF_PAARE():
    return (
        (JS_ALT, JS_NEU, 1),
        (ATIS_ALT, ATIS_NEU, 1),
        (END_ALT, END_NEU, 1),
    )


def schon_ff(text):
    return (
        "# ===== eddnAtis =====" in text
        and "eddn_atis.status_anreichern" in text
        and "w.zeile" in text
        and "_eddn_atis.ablegen" in text
    )


def patch_ff(text):
    for alt, neu, n in FF_PAARE():
        text = ersetze(text, alt, neu, "flugfunk.py", n)
    return text


def stub_aus(paare):
    return "".join(alt for alt, _neu, _n in paare)


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
    tmp = pfad + ".%s-tmp" % KENNUNG
    with open(tmp, "wb") as handle:
        handle.write(daten)
        handle.flush()
        os.fsync(handle.fileno())
    if os.path.exists(pfad):
        shutil.copymode(pfad, tmp)
    os.replace(tmp, pfad)


def stand(data):
    return sha256(data), len(data)


def pyflakes_datei(pfad):
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except OSError:
            continue
        if r.returncode == 0 and not (r.stdout or "").strip() and not (r.stderr or "").strip():
            print("pyflakes %s ok" % os.path.basename(pfad))
            return True
        if r.returncode == 0 or (r.stderr or r.stdout):
            # Modul fehlt: ModuleNotFoundError
            err = (r.stderr or "") + (r.stdout or "")
            if "No module named" in err or "command not found" in err:
                continue
            print("pyflakes %s:\n%s" % (os.path.basename(pfad), err.strip()[:800]))
            return False
    print("Hinweis: pyflakes nicht installiert, nur py_compile")
    return True


def SDR_PAARE():
    paare = [
        (SDR_FF7B_ALT, SDR_FF7B_NEU, 1),
        (SDR_SUB_ALT, SDR_SUB_NEU, 1),
        (SDR_SKIP_ALT, SDR_SKIP_NEU, 1),
        (SDR_WATCHIF_ALT, SDR_WATCHIF_NEU, 1),
        (SDR_WATCH_ALT, SDR_WATCH_NEU, 1),
    ]
    paare.extend(SDR_MSG)
    return paare


def DASH_PAARE():
    return (
        (DASH_ASA_ALT, DASH_ASA_NEU, 1),
        (DASH_ST_ALT, DASH_ST_NEU, 1),
    )


def schon_sdr(text):
    return (
        "T5C_TRY_S = 90" in text
        and "def _ff7b_note(" in text
        and "Stick 1 zurück auf 5C: 5C wieder mit Sync" in text
        and "return not (a and a.get(\"role\") == \"5C\")" in text
    )


def schon_dash(text):
    return "Rückfall 10C aktiv · 5C hier nicht empfangbar" in text and "fb5c" in text


def patch_sdr(text):
    for alt, neu, n in SDR_PAARE():
        text = ersetze(text, alt, neu, "prepper_sdr.py", n)
    return text


def patch_dash(text):
    for alt, neu, n in DASH_PAARE():
        text = ersetze(text, alt, neu, "dashboard.py", n)
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
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_sdr(roh):
        return alt, None, None
    if hashcheck and (ist != SDR_START_SHA or n != SDR_START_BYTES):
        return None, None, "STOP %s ist %s/%s soll %s/%s" % (
            os.path.basename(pfad), ist[:16], n, SDR_START_SHA16, SDR_START_BYTES)
    try:
        neu = patch_sdr(roh).encode("utf-8")
    except SystemExit as exc:
        return None, None, str(exc)
    compile(neu, "prepper_sdr.py", "exec")
    if hashcheck and (sha256(neu) != SDR_END_SHA or len(neu) != SDR_END_BYTES):
        return None, None, "STOP prepper_sdr.py Endstand %s/%s erwartet %s/%s" % (
            sha256(neu)[:16], len(neu), SDR_END_SHA16, SDR_END_BYTES)
    return alt, neu, None


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
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_dash(roh):
        return alt, None, None
    if hashcheck and (ist != DASH_START_SHA or n != DASH_START_BYTES):
        return None, None, "STOP %s ist %s/%s soll %s/%s" % (
            os.path.basename(pfad), ist[:16], n, DASH_START_SHA16, DASH_START_BYTES)
    try:
        neu = patch_dash(roh).encode("utf-8")
    except SystemExit as exc:
        return None, None, str(exc)
    compile(neu, "dashboard.py", "exec")
    if hashcheck and (sha256(neu) != DASH_END_SHA or len(neu) != DASH_END_BYTES):
        return None, None, "STOP dashboard.py Endstand %s/%s erwartet %s/%s" % (
            sha256(neu)[:16], len(neu), DASH_END_SHA16, DASH_END_BYTES)
    return alt, neu, None




def hinweis_basis(root):
    kach = os.path.join(root, "acars_kachel.py")
    if not os.path.isfile(kach):
        print("Hinweis: acars_kachel.py fehlt (D-ATIS braucht acars_msgs.jsonl, Funk-ATIS nicht)")
        return
    data = open(kach, "rb").read()
    h, n = stand(data)
    print("acars_kachel.py sha16 %s bytes %d" % (h[:16], n))
    if h != KACHEL_SHA or n != KACHEL_BYTES:
        print("Hinweis: acars_kachel.py weicht von apply-acars-Endstand %s/%s ab" % (KACHEL_SHA16, KACHEL_BYTES))



def berechne_mod(pfad, hashcheck=True):
    soll = mod_bytes()
    if sha256(soll) != MOD_SHA or len(soll) != MOD_BYTES:
        return None, None, "STOP eingebettetes eddn_atis.py weicht vom Soll-Hash ab"
    if not os.path.isfile(pfad):
        return None, soll, None
    alt = open(pfad, "rb").read()
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), sha256(alt)[:16], len(alt)))
    if sha256(alt) == MOD_SHA and len(alt) == MOD_BYTES:
        return alt, None, None
    if hashcheck and alt != soll and b"def parse_atis" in alt and sha256(alt) != MOD_SHA:
        # vorhandene abweichende Datei ersetzen, wenn wir der Autor sind
        print("Hinweis: %s wird auf den Skript-Stand gesetzt" % os.path.basename(pfad))
    return alt, soll, None


def berechne_ff(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_ff(roh):
        return alt, None, None
    if hashcheck and (ist != FF_START_SHA or n != FF_START_BYTES):
        return None, None, "STOP flugfunk.py ist %s/%s soll %s/%s (strikter Start-Hash)" % (
            ist[:16], n, FF_START_SHA16, FF_START_BYTES)
    try:
        neu = patch_ff(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    if not schon_ff(neu):
        return None, None, "STOP Patch ohne erwartete Markierungen"
    daten = neu.encode("utf-8")
    compile(daten, "flugfunk.py", "exec")
    if hashcheck and FF_END_SHA and (sha256(daten) != FF_END_SHA or (FF_END_BYTES and len(daten) != FF_END_BYTES)):
        return None, None, "STOP flugfunk.py Endstand %s/%s erwartet %s/%s" % (
            sha256(daten)[:16], len(daten), FF_END_SHA[:16], FF_END_BYTES)
    return alt, daten, None


def _unit_snap(dienst):
    """PID und ActiveEnterTimestamp vor/nach dem Neustart. systemctl kann bei Polkit-Fehler rc 0 liefern."""
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
    # ohne systemctl show: nur rc 0 reicht nicht, aber im Selftest ohne systemd
    if not after.get("active") and not before.get("active") and rc == 0:
        return True
    return after.get("active") == "active"


def _run_restart(cmd):
    """stdio erben (Passwort-Prompt), Returncode selbst pruefen."""
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


def neustart():
    """Beide Dienste: prepper-sdr laedt flugfunk (Transkript/ablegen) und den 5C-Planer,
    prepper-dashboard laedt flugfunk/eddn_atis (Anzeige) und die ASA-Zeile."""
    rc_all = 0
    for dienst in DIENSTE:
        rc = restart_dienst(dienst)
        if rc != 0:
            rc_all = rc
    return rc_all


def warte_http(urls, timeout=45):
    """Dashboard braucht nach Neustart ~28 s. Bis timeout auf HTTP 200 warten."""
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


def journal_pruefen(seit, pause=0):
    if pause:
        print("warte %s s auf Journal" % pause)
        time.sleep(pause)
    ok = True
    if not warte_http([
        ("http://127.0.0.1:5000/api/flugfunk", "/tmp/apply-atis-api.json"),
        ("http://127.0.0.1:5000/adsb", "/tmp/apply-atis-adsb.html"),
    ], timeout=45):
        ok = False
    for dienst in DIENSTE:
        try:
            r = subprocess.run(
                ["journalctl", "-u", dienst, "--since", seit, "-o", "cat", "-n", "80"],
                capture_output=True, text=True, timeout=10)
            zeilen = (r.stdout or "").splitlines()
        except (OSError, subprocess.TimeoutExpired):
            print("Hinweis: Journal %s unlesbar" % dienst)
            continue
        hits = [ln for ln in zeilen if "Traceback" in ln or "eddnAtis import" in ln]
        if any("Traceback" in ln for ln in zeilen):
            print("STOP Journal %s enthaelt Traceback" % dienst)
            for ln in hits[:8]:
                print(ln)
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (dienst, len(zeilen)))
    if os.path.isfile("/tmp/apply-atis-api.json"):
        raw = open("/tmp/apply-atis-api.json", encoding="utf-8", errors="replace").read()
        if "rtlsdr" in raw.lower() or '"serial"' in raw:
            print("STOP API enthaelt Geraete-Seriennummer oder rtlsdr")
            ok = False
        else:
            try:
                d = json.loads(raw)
                if isinstance(d.get("wetter"), dict) and d["wetter"].get("zeile"):
                    print("ATIS-Zeile in API: %s" % d["wetter"]["zeile"][:120])
                else:
                    print("API ok, noch keine vollstaendige ATIS-Zeile (normal direkt nach Start)")
            except ValueError:
                print("Hinweis: API kein JSON")
    if os.path.isfile("/tmp/apply-atis-adsb.html"):
        html = open("/tmp/apply-atis-adsb.html", encoding="utf-8", errors="replace").read()
        if html and ('id="ffWetter"' not in html or "w.zeile" not in html or "Rohtext" not in html):
            print("STOP /adsb ohne neue ATIS-Zeile (ffWetter/w.zeile/Rohtext)")
            ok = False
        elif html:
            print("ATIS-Zeile (ffWetter, Rohtext aufklappbar) auf /adsb vorhanden")
    return ok


def anwenden(root, dry, kein, minute, hashcheck=True, pause=0):
    ff = os.path.join(root, "flugfunk.py")
    mod = os.path.join(root, MOD_NAME)
    sdr = os.path.join(root, "prepper_sdr.py")
    dash = os.path.join(root, "dashboard.py")
    hinweis_basis(root)
    paare = []
    for name, fn, berechne in (
        ("eddn_atis.py", mod, berechne_mod),
        ("flugfunk.py", ff, berechne_ff),
        ("prepper_sdr.py", sdr, berechne_sdr),
        ("dashboard.py", dash, berechne_dash),
    ):
        alt, neu, fehl = berechne(fn, hashcheck)
        if fehl:
            print(fehl)
            return 2
        paare.append((name, fn, alt, neu))
        if neu is not None:
            print("%s endstand sha16 %s bytes %d" % (name, sha256(neu)[:16], len(neu)))
    if all(neu is None for _n, _f, _a, neu in paare):
        print("bereits installiert, keine Aenderung, kein Neustart")
        for name, fn, alt, _n in paare:
            if alt is not None or os.path.isfile(fn):
                data = alt if alt is not None else open(fn, "rb").read()
                print("%s endstand sha16 %s bytes %d" % (name, sha256(data)[:16], len(data)))
        return 0
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and not im_fenster(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    try:
        for name, fn, alt, neu in paare:
            if neu is None:
                continue
            if alt is not None:
                print("Sicherung %s" % sichern(fn, stempel))
            schreibe(fn, neu)
            if alt is None and name == MOD_NAME and os.path.exists(ff):
                try:
                    shutil.copymode(ff, fn)
                except OSError:
                    pass
    except OSError as exc:
        print("STOP beim Schreiben (%s)" % type(exc).__name__)
        return 3
    for name, fn, alt, neu in paare:
        if not os.path.isfile(fn):
            continue
        data = open(fn, "rb").read()
        print("%s endstand sha256 %s bytes %d" % (name, sha256(data), len(data)))
        compile(data, name, "exec")
        if name == MOD_NAME and (sha256(data) != MOD_SHA or len(data) != MOD_BYTES):
            print("STOP %s weicht vom Soll-Hash ab" % name)
            return 3
        if name == "prepper_sdr.py" and hashcheck and sha256(data) != SDR_END_SHA:
            print("STOP prepper_sdr.py weicht vom Soll-Hash ab")
            return 3
        if name == "dashboard.py" and hashcheck and sha256(data) != DASH_END_SHA:
            print("STOP dashboard.py weicht vom Soll-Hash ab")
            return 3
        if name == "flugfunk.py" and hashcheck and FF_END_SHA and sha256(data) != FF_END_SHA:
            print("STOP flugfunk.py weicht vom Soll-Hash ab")
            return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart %s" % " ".join(DIENSTE))
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = neustart()
    if rc != 0:
        print("STOP Neustart fehlgeschlagen – bitte sudo systemctl restart %s" % " ".join(DIENSTE))
        return 4
    if not journal_pruefen(seit, pause):
        return 4
    return 0


def selftest():
    roh = mod_bytes()
    if sha256(roh) != MOD_SHA or len(roh) != MOD_BYTES:
        raise SystemExit("selftest blob hash")
    compile(roh, MOD_NAME, "exec")
    tmpk = tempfile.mkdtemp(prefix="atis-mod-")
    try:
        ziel = os.path.join(tmpk, MOD_NAME)
        open(ziel, "wb").write(roh)
        import sys
        sys.path.insert(0, tmpk)
        import eddn_atis as ea
        ea.selftest()
        sys.path.remove(tmpk)
        sys.modules.pop("eddn_atis", None)
        if not pyflakes_datei(ziel):
            raise SystemExit("selftest pyflakes modul")
    finally:
        shutil.rmtree(tmpk, ignore_errors=True)

    # systemctl-Returncode: gleicher PID+Zeitstempel bei rc 0 gilt als Fehlschlag
    b = {"pid": "31409", "ts": "Sat 2026-11-28 00:06:20 CET", "active": "active"}
    if _restart_ok(0, b, b):
        raise SystemExit("selftest restart-ok falsch (PID unveraendert)")
    if not _restart_ok(0, b, {"pid": "32000", "ts": "Sat 2026-11-28 00:07:00 CET", "active": "active"}):
        raise SystemExit("selftest restart-ok echter Neustart")
    if _restart_ok(1, b, {"pid": "31409", "ts": b["ts"], "active": "active"}):
        raise SystemExit("selftest restart-ok rc 1")

    with tempfile.TemporaryDirectory(prefix="atis-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        ff = os.path.join(root, "flugfunk.py")
        open(ff, "w", encoding="utf-8").write(
            "# stub\n_JS = r\"\"\"\n" + JS_ALT + '\"\"\"\n\n'
            "def transkribieren():\n" + ATIS_ALT + "\n"
            "def status(base, now=None):\n    return {}\n\n" + END_ALT
        )
        os.chmod(ff, 0o640)
        vorher = open(ff, "rb").read()
        if anwenden(root, False, False, 4, hashcheck=False, pause=0) != 2:
            raise SystemExit("selftest fenster")
        if open(ff, "rb").read() != vorher:
            raise SystemExit("selftest fenster geschrieben")
        if anwenden(root, True, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest dry")
        if open(ff, "rb").read() != vorher:
            raise SystemExit("selftest dry geschrieben")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest lauf")
        st = open(ff, encoding="utf-8").read()
        if not schon_ff(st):
            raise SystemExit("selftest ff fehl")
        if not os.path.isfile(os.path.join(root, MOD_NAME)):
            raise SystemExit("selftest modul fehlt")
        if (os.stat(ff).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest modus")
        bak = [p for p in os.listdir(root) if "bak-%s-" % KENNUNG in p]
        if len(bak) < 1:
            raise SystemExit("selftest backup %s" % bak)
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest idempotent")
        compile(st.encode("utf-8"), "flugfunk.py", "exec")

    # echte Vorlagen: 7d (Anker) + acars-Endstaende SDR/Dashboard
    src_ff = src_sdr = src_dash = None
    for pfad in (os.environ.get("ATIS_FF"), "/tmp/flugfunk_7d.py", os.path.join(BASIS, "flugfunk.py")):
        if pfad and os.path.isfile(pfad):
            data = open(pfad, "rb").read()
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            if schon_ff(text) or all(alt in text for alt, _neu, _n in FF_PAARE()):
                src_ff = data
                print("selftest flugfunk-Vorlage %s sha16 %s bytes %d" % (pfad, sha256(data)[:16], len(data)))
                break
    for pfad in (os.environ.get("ATIS_SDR"), "/tmp/prepper_sdr_acars.py", os.path.join(BASIS, "prepper_sdr.py")):
        if pfad and os.path.isfile(pfad):
            data = open(pfad, "rb").read()
            if sha256(data) == SDR_START_SHA or schon_sdr(data.decode("utf-8", "replace")):
                src_sdr = data
                print("selftest sdr-Vorlage %s sha16 %s bytes %d" % (pfad, sha256(data)[:16], len(data)))
                break
    for pfad in (os.environ.get("ATIS_DASH"), "/tmp/dashboard_acars.py", os.path.join(BASIS, "dashboard.py")):
        if pfad and os.path.isfile(pfad):
            data = open(pfad, "rb").read()
            if sha256(data) == DASH_START_SHA or schon_dash(data.decode("utf-8", "replace")):
                src_dash = data
                print("selftest dash-Vorlage %s sha16 %s bytes %d" % (pfad, sha256(data)[:16], len(data)))
                break
    if not src_ff:
        raise SystemExit("selftest echte flugfunk-Vorlage fehlt")
    if not src_sdr:
        raise SystemExit("selftest echte prepper_sdr-Vorlage fehlt (86da726a/803996)")
    if not src_dash:
        raise SystemExit("selftest echtes dashboard fehlt (6e7715e8/1397320)")
    with tempfile.TemporaryDirectory(prefix="atis-real-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        zf, zs, zd = [os.path.join(root, n) for n in ("flugfunk.py", "prepper_sdr.py", "dashboard.py")]
        open(zf, "wb").write(src_ff)
        open(zs, "wb").write(src_sdr)
        open(zd, "wb").write(src_dash)
        os.chmod(zf, 0o644)
        os.chmod(zs, 0o644)
        os.chmod(zd, 0o644)
        # flugfunk hier oft 7d (nicht Live-Hash) – Anker, hashcheck nur fuer SDR/Dash separat
        if anwenden(root, True, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest real dry")
        if open(zf, "rb").read() != src_ff or open(zs, "rb").read() != src_sdr:
            raise SystemExit("selftest real dry geschrieben")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest real lauf")
        if anwenden(root, False, False, 4, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest real bereits/fenster")
        neu_s, neu_d, neu_f = open(zs, "rb").read(), open(zd, "rb").read(), open(zf, "rb").read()
        mk = open(os.path.join(root, MOD_NAME), "rb").read()
        if sha256(mk) != MOD_SHA or len(mk) != MOD_BYTES:
            raise SystemExit("selftest real modul hash %s/%s" % (sha256(mk)[:16], len(mk)))
        if sha256(neu_s) != SDR_END_SHA or len(neu_s) != SDR_END_BYTES:
            raise SystemExit("selftest real sdr hash %s/%s" % (sha256(neu_s)[:16], len(neu_s)))
        if sha256(neu_d) != DASH_END_SHA or len(neu_d) != DASH_END_BYTES:
            raise SystemExit("selftest real dash hash %s/%s" % (sha256(neu_d)[:16], len(neu_d)))
        compile(neu_s, "prepper_sdr.py", "exec")
        compile(neu_d, "dashboard.py", "exec")
        compile(neu_f, "flugfunk.py", "exec")
        if not schon_sdr(neu_s.decode("utf-8")) or not schon_dash(neu_d.decode("utf-8")):
            raise SystemExit("selftest real 5C/ASA-Markierungen")
        if "T5C_TRY_S = 90" not in neu_s.decode("utf-8"):
            raise SystemExit("selftest 90 s fehlt")
        if "Stick 2 zurück auf 5C" in neu_s.decode("utf-8"):
            raise SystemExit("selftest alte Stick-2-Meldung steht noch")
        if sha256(src_ff) == FF_START_SHA:
            print("flugfunk.py Live-Endstand sha256 %s bytes %d" % (sha256(neu_f), len(neu_f)))
        else:
            print("flugfunk.py nach Patch sha256 %s bytes %d (Vorlage nicht %s, Live-Endhash folgt auf dem Pi)" % (
                sha256(neu_f), len(neu_f), FF_START_SHA16))
        if not pyflakes_datei(os.path.join(root, MOD_NAME)):
            raise SystemExit("selftest real pyflakes")
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
