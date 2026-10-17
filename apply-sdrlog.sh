#!/bin/bash
set -euo pipefail
# sdrLog (Teil 1 von 2 der Funk-Seiten-Ueberarbeitung): prepper_sdr.py fuehrt einen Technik-Verlauf sdr_techlog.json (+ Archiv archive/techlog/):
# DAB-Sync verloren/wieder da je Kanal, Mast gesehen/weg, Ensemble-ID-Wechsel, Stick-2-Uebernahme Start/Ende, Rueckfall 10C Start/Ende + zurueck auf 5C,
# Kalibrierergebnis, Meteor-Aufnahme. Masten im Technik-Verlauf mit Klarnamen vor dem TII-Code (Bamberg (Geisberg) · 08/18, sonst unbekannt · MM/SS). DAB-Verlauf sdr_dabhist.json speichert keine Musiktitel/Programmtexte mehr (nur BR24-Nachrichten, ASA, Warnungen),
# der Rest wird je Sender gezaehlt. Meteor: Vorschaubilder meteor/thumbs/ (480 px, PIL, sonst ohne), Aufbewahrung 60 Bilder / 300 MB.
# Aendert nur prepper_sdr.py; dashboard.py, sdr_manager.py, database.py, mesh_router.py, lagegeo.py bleiben unveraendert.
# Neustart nur prepper-sdr. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdrlog-apply
KEEP_LAST=3
KNOWN_D16="95e74a7b2fd00e4d"     # dashboard.py nach sqlC
KNOWN_D16F="ccccd6476c2ab2e4"     # dashboard.py nach funkUI
KNOWN_SM16="682045d52602f371"    # sdr_manager.py nach sqlC
KNOWN_SM16F="4cbc77c70193bacd"    # sdr_manager.py nach funkUI
KNOWN_SDR16="0fc4850dd84ff76e"   # prepper_sdr.py nach sqlC
KNOWN_SDR16N="786f2c925f0e88a7"   # prepper_sdr.py nach sdrLog (Ziel)
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
echo "=== sdrLog apply (Technik-Verlauf, DAB-Verlauf ohne Musik, Meteor-Vorschaubilder), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_PF="24ca150b11f4c77b5d34085330c7cc64c90e5795e498cde56fb0f2562ae906ef"
cat > "$W/patch-fu.py" << 'FUP_EOF'
"""Patcher fuer sdrLog/funkUI. Aufruf: patch-fu.py NAME ART QUELLE ZIEL BLOCK EDITS   (ART = sm | sdr | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E, ANCH = g["%s_EDITS" % kind.upper()], g["%s_ANCHOR" % kind.upper()]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
MARK = B.splitlines()[0]
name = {"sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard"}[kind]
if MARK in s:
    rest = s.replace(B, "", 1)
    ok = s.count(B) == 1 and all(rest.count(n) == 1 for o, n in E)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if s.count(ANCH) != 1:
    print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
if kind == "dash":
    i = s.index(ANCH) + len(ANCH)
    s = s[:i] + B + s[i:]
else:
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen + Block %s" % (name, len(E), label))
FUP_EOF
EXPECT_ED="006ada2c0e3c2ef9a303c73e3908bc5c755ac7b8556366b2eddbf224af4c2ad6"
cat > "$W/sl_edits.py" << 'FUE_EOF'
# sdrLog: Stellen (alt, neu) in prepper_sdr.py. Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('''        self.ev = [x for x in (ev or []) if isinstance(x, dict) and isinstance(x.get("t"), (int, float))][-self.MAX_N:]
        self.seq = max([x.get("id", 0) for x in self.ev if isinstance(x.get("id"), int)] + [0])
''', '''        self.ev = [x for x in (ev or []) if isinstance(x, dict) and isinstance(x.get("t"), (int, float))][-self.MAX_N:]
        self.skip = d.get("skip") if isinstance(d, dict) and isinstance(d.get("skip"), dict) else {}   # sdrLog: nicht gespeicherte Programm-Texte je Sender
        self.seq = max([x.get("id", 0) for x in self.ev if isinstance(x.get("id"), int)] + [0])
'''),
('''                write_json(self.f, {"v": 1, "t": int(now), "ev": self.ev})''',
 '''                write_json(self.f, {"v": 1, "t": int(now), "ev": self.ev, "skip": getattr(self, "skip", {})})   # sdrLog'''),
('''        keep = int(self.cfg.get("meteor_keep") or 30)''',
 '''        keep = int(self.cfg.get("meteor_keep") or 60)   # sdrLog: 60 Bilder (300 MB)'''),
('''        selftest_sqlc()
    elif a in''', '''        selftest_sqlc()
        selftest_sdrlog()
    elif a in'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
FUE_EOF
EXPECT_BL="1239f2577d3b1e64ff1e7f615cc7aa9128d4d4582c08a6dfd0e82076f35d912f"
cat > "$W/sl_sdr_block.py" << 'FUB_EOF'
# ===== sdrLog: Technik-Verlauf sdr_techlog.json (+ archive/techlog/YYYY-MM/*.jsonl) - Sync verloren/wieder da je Kanal (2 Pruefungen), Ensemble-ID-Wechsel, Mast gesehen/weg (stabile TII), FIG 0/9 + Label aus Teil 2, Stick-2-Uebernahme Beginn/Ende, Rueckfall 10C Beginn/Ende/zurueck auf 5C, Kalibrierung, Meteor-Ueberflug; DAB-Verlauf ohne Musiktitel (nur BR24, ASA, Warnungen/Ansagen; Rest gezaehlt); Meteor-Vorschaubilder meteor/thumbs/ (PIL, sonst ohne) und 60 Bilder; nur Empfang, sendet nichts =====
SDRLOG_FILE = "sdr_techlog.json"
SDRLOG_MAX = 2000
SDRLOG_LOST_N = 2            # Sync erst nach 2 Pruefungen ohne Sync nacheinander als "verloren" (wieder da sofort)
SDRLOG_THUMB_W = 480         # Vorschaubild-Breite (px)
_SDRLOG = {}
_SDRLOG_LOCK = threading.Lock()


def sdrlog_keep_dls(ch, src, warn, kind):
    """Nur BR24-Nachrichten (11D), ASA-Dienste, Warnungen und Ansagen in den DAB-Verlauf; Musiktitel/Programm der anderen Sender nicht."""
    if kind != "dls" or warn:
        return True
    s = str(src or "").strip()
    return bool(ASA_RE.match(s)) or (str(ch).upper() == "11D" and s.upper().startswith("BR24"))


class TechLog:
    def __init__(self, base):
        self.base = base
        self.f = p(SDRLOG_FILE, base)
        d = load_json(self.f, {}) or {}
        d = d if isinstance(d, dict) else {}
        self.ev = [x for x in (d.get("ev") or []) if isinstance(x, dict) and isinstance(x.get("t"), (int, float))][-SDRLOG_MAX:]
        self.st = d.get("st") if isinstance(d.get("st"), dict) else {}
        self.seq = max([x.get("id", 0) for x in self.ev if isinstance(x.get("id"), int)] + [0])
        self.cand = {}

    def add(self, k, cat, text, now, ch=None, lvl="info", save=True, **kw):
        e = dict({"id": self.seq + 1, "t": int(now), "k": str(k)[:20], "cat": cat, "lvl": lvl, "ch": (str(ch).upper()[:6] if ch else None),
                  "text": " ".join(str(text or "").split())[:240]}, **kw)
        self.seq += 1
        self.ev = (self.ev + [e])[-SDRLOG_MAX:]
        self.archive(e)
        if save:
            self.save()
        if not self.__dict__.get("quiet"):
            print("sdrLog: %s" % e["text"], flush=True)
        return e

    def archive(self, e):
        try:
            lt = time.localtime(e["t"])
            d = p(os.path.join("archive", "techlog", time.strftime("%Y-%m", lt)), self.base)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "techlog-%s.jsonl" % time.strftime("%Y-%m-%d", lt)), "a", encoding="utf-8") as f:
                f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
        except Exception as ex:
            print("sdrLog Archiv:", ex, flush=True)

    def save(self):
        try:
            write_json(self.f, {"v": 1, "t": int(time.time()), "ev": self.ev, "st": self.st})
        except Exception as ex:
            print("sdrLog speichern:", ex, flush=True)

    # ---- DAB: Sync, Ensemble-ID, Masten, Teil-2-Ereignisse ----
    def dab(self, ch, e, fig, t2ev, now):
        ch = str(ch).upper()
        chg = False
        sy = self.st.setdefault("sync", {})
        rx = e.get("rx")
        if rx is True or rx is False:
            prev = sy.get(ch)
            if rx is True:
                self.cand.pop(ch, None)
                if prev is not True:
                    if prev is False:
                        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
                        snr = dm.get("snr")
                        self.add("sync_ok", "tech", "DAB %s Sync wieder da%s%s" % (ch, (" · Ensemble %s" % e["ensemble"]) if e.get("ensemble") else "",
                                                                                 (" · SNR %.1f dB" % snr) if isinstance(snr, (int, float)) else ""), now, ch, "ok", save=False)
                    sy[ch] = True
                    chg = True
            else:
                n = self.cand.get(ch, 0) + 1
                self.cand[ch] = n
                if prev is None:
                    sy[ch] = False
                    chg = True
                elif prev is True and n >= SDRLOG_LOST_N:
                    self.add("sync_lost", "tech", "DAB %s Sync verloren (%s, %d Prüfungen ohne Sync)" % (ch, e.get("rx_why") or "kein Sync", n), now, ch, "gelb", save=False)
                    sy[ch] = False
                    chg = True
        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
        eid = dm.get("ens_id") if rx is True else None
        if isinstance(eid, str) and eid and eid.lower() not in ("0x0000", "0x0"):
            ei = self.st.setdefault("ens", {})
            if ei.get(ch) != eid:
                if ei.get(ch):
                    self.add("ens_id", "tech", "DAB %s Ensemble-ID geändert: %s -> %s%s" % (ch, ei[ch], eid, (" (%s)" % e["ensemble"]) if e.get("ensemble") else ""), now, ch, "gelb", save=False)
                ei[ch] = eid
                chg = True
        f = fig.get(ch) if isinstance(fig, dict) and isinstance(fig.get(ch), dict) else None
        if f is not None and isinstance(f.get("tii_set"), list):
            ts = self.st.setdefault("tii", {})
            cur, old = sorted(str(x) for x in f["tii_set"]), ts.get(ch)
            if cur != old:
                o = set(old or [])
                for x in cur:
                    if x not in o:
                        self.add("mast_new", "tech", "DAB %s Mast %s: %s" % (ch, "gesehen" if old is not None else "erstmals", self._mast(ch, x)), now, ch, "info", save=False)
                for x in sorted(o - set(cur)):
                    self.add("mast_lost", "tech", "DAB %s Mast nicht mehr empfangen: %s" % (ch, self._mast(ch, x)), now, ch, "gelb", save=False)
                ts[ch] = cur
                chg = True
        seen = self.st.setdefault("t2ids", [])
        for x in (t2ev or [])[-40:]:
            if isinstance(x, dict) and x.get("id") and x.get("k") in ("fig09", "label") and x["id"] not in seen:
                self.add(x["k"], "tech", x.get("text") or x["k"], x.get("t") or now, x.get("ch") or ch, "info", save=False, ref=str(x["id"])[:60])
                seen.append(x["id"])
                del seen[:-80]
                chg = True
        return chg

    def _mast(self, ch, x):
        """Klarname vor TII-Code: "Bamberg (Geisberg) · 08/18"; nicht in MASTS_DB: "unbekannt · 00/18"."""
        try:
            a, b = (int(v) for v in str(x).split("/"))
            for t in (MASTS_DB.get(str(ch)) or {}).get("tii") or []:
                if t.get("main") == a and t.get("sub") == b and t.get("mast"):
                    return "%s · %02d/%02d" % (t["mast"], a, b)
            return "unbekannt · %02d/%02d" % (a, b)
        except Exception:
            return "unbekannt · %s" % str(x)[:12]

    # ---- Stick 2: Uebernahme, Rueckfall 10C ----
    def stick(self, to_on, to, fb, alarm, now):
        chg = False
        if to_on is not None and self.st.get("to") != to_on:
            if self.st.get("to") is not None:
                if to_on:
                    self.add("takeover_on", "stick", "Stick 2 Übernahme: fest auf 5C (ASA DE), Auslöser %s%s" % (to.get("src") or "?", (": " + to["why"]) if to.get("why") else ""), now, "5C", "rot", save=False)
                else:
                    self.add("takeover_off", "stick", "Stick 2 Übernahme beendet - zurück im Hobby-Betrieb", now, None, "ok", save=False)
            self.st["to"] = to_on
            chg = True
        if fb is not None and self.st.get("fb") != fb:
            if self.st.get("fb") is not None:
                if fb:
                    self.add("fb10c_on", "stick", "Stick 2 Rückfall 10C (Lokal Nürnberg): 5C ohne Sync nach %d Prüfungen, 5C-Versuch alle %d min" % (T4_FB_AFTER, T4_RETRY_S // 60), now, "10C", "gelb", save=False)
                elif alarm:
                    self.add("back5c", "stick", "Stick 2 zurück auf 5C: 5C wieder mit Sync (Rückfall 10C beendet)", now, "5C", "ok", save=False)
                else:
                    self.add("fb10c_off", "stick", "Stick 2 Rückfall 10C beendet (Übernahme aus)", now, "10C", "ok", save=False)
            self.st["fb"] = fb
            chg = True
        return chg


def sdrlog_get(base):
    tl = _SDRLOG.get(base)
    if tl is None:
        tl = _SDRLOG[base] = TechLog(base)
    return tl


_sdrlog_orig_dabhist_note = dabhist_note


def dabhist_note(bc, ch, src, text, warn, now, kind="dls"):
    """sdrLog: Musik/Programm-Texte nicht mehr speichern, nur je Sender zaehlen."""
    try:
        if not sdrlog_keep_dls(ch, src, warn, kind):
            dh = getattr(bc, "_dabhist", None)
            if dh is None:
                dh = bc._dabhist = DabHist(os.path.dirname(bc.f))
            k = ("%s|%s" % (str(ch).upper(), str(src or "?").strip()[:30]))
            sk = dh.__dict__.setdefault("skip", {})
            sk[k] = int(sk.get(k) or 0) + 1
            dh.skip_t = int(now)
            dh.dirty = True
            dh.save()
            return None
    except Exception as ex:
        print("sdrLog dabHist:", ex, flush=True)
    return _sdrlog_orig_dabhist_note(bc, ch, src, text, warn, now, kind)


_sdrlog_orig_on_dab = StateBC.on_dab


def _sdrlog_on_dab(self, ch, mux, now=None):
    r = _sdrlog_orig_on_dab(self, ch, mux, now)
    try:
        t = float(now or time.time())
        e = (self.d.get("dab") or {}).get(ch) or {}
        t2 = self.d.get("t2") if isinstance(self.d.get("t2"), dict) else {}
        with _SDRLOG_LOCK:
            tl = sdrlog_get(os.path.dirname(self.f))
            if tl.dab(ch, e, t2.get("fig") or {}, t2.get("ev") or [], t):
                tl.save()
    except Exception as ex:
        print("sdrLog on_dab:", ex, flush=True)
    return r


def _sdrlog_watch(self, now):
    """Stick-2-Zustand (Uebernahme, Rueckfall 10C) - nur auf dem Planer mit Rolle rot, hoechstens alle 5 s."""
    try:
        if getattr(self, "role", None) != "rot" or not t2_on(self):
            return
        if now - float(self.__dict__.get("_sdrlog_w") or 0) < 5:
            return
        self.__dict__["_sdrlog_w"] = now
        to = t2_takeover(self.base)
        al = bool(_t2_alarm(self))
        st4 = self.__dict__.get("_t4")
        fb = bool(st4.get("fb")) if isinstance(st4, dict) else False
        with _SDRLOG_LOCK:
            tl = sdrlog_get(self.base)
            if tl.stick(bool(to.get("on")), to, fb, al, now):
                tl.save()
    except Exception as ex:
        print("sdrLog Stick 2:", ex, flush=True)


_sdrlog_orig_want = Planner.want
_sdrlog_orig_sub_done = Planner.sub_done
_sdrlog_orig_cal_finish = Planner.cal_finish
_sdrlog_orig_collect_meteor = Planner.collect_meteor


def _sdrlog_want(self, mode, now):
    r = _sdrlog_orig_want(self, mode, now)
    _sdrlog_watch(self, now)
    return r


def _sdrlog_sub_done(self, sp, now):
    try:
        return _sdrlog_orig_sub_done(self, sp, now)
    finally:
        _sdrlog_watch(self, now)


def _sdrlog_cal_finish(self, now):
    _sdrlog_orig_cal_finish(self, now)
    try:
        rec = self.cfg.get("ppm_cal") if isinstance(self.cfg.get("ppm_cal"), dict) else {}
        if rec.get("try_t") == int(now):
            n = int(getattr(self, "stickno", 1) or 1)
            ok = rec.get("t") == int(now) and isinstance(rec.get("ppm"), (int, float))
            tx = ("Kalibrierung Stick %d (%s): %+.2f ppm, angewendet %+d%s" % (n, rec.get("ch") or "?", rec["ppm"], ppm_val(self.cfg), (" · " + str(rec["note"])) if rec.get("note") else "")
                  if ok else "Kalibrierung Stick %d (%s): kein Ergebnis%s - alter Wert bleibt" % (n, rec.get("ch") or "?", (" (" + str(rec["note"]) + ")") if rec.get("note") else ""))
            with _SDRLOG_LOCK:
                sdrlog_get(self.base).add("cal", "tech", tx, now, rec.get("ch"), "ok" if ok else "gelb")
    except Exception as ex:
        print("sdrLog Kalibrierung:", ex, flush=True)


def sdrlog_thumbs(base):
    """Vorschaubilder meteor/thumbs/<name>.jpg (480 px) fuer alle Bilder ohne; verwaiste loeschen. -> (neu, PIL da?)"""
    d = p("meteor", base)
    td = os.path.join(d, "thumbs")
    if not os.path.isdir(d):
        return 0, None
    try:
        from PIL import Image
    except Exception:
        Image = None
    imgs = [f for f in os.listdir(d) if f.endswith((".jpg", ".png")) and os.path.isfile(os.path.join(d, f))]
    n = 0
    if Image is not None:
        os.makedirs(td, exist_ok=True)
        for f in imgs:
            out = os.path.join(td, os.path.splitext(f)[0] + ".jpg")
            if os.path.exists(out):
                continue
            try:
                im = Image.open(os.path.join(d, f)).convert("RGB")
                if im.width > SDRLOG_THUMB_W:
                    im = im.resize((SDRLOG_THUMB_W, max(1, int(im.height * SDRLOG_THUMB_W / im.width))))
                im.save(out + ".tmp", "JPEG", quality=75)
                os.replace(out + ".tmp", out)
                n += 1
            except Exception as ex:
                print("sdrLog Vorschaubild %s: %s" % (f, ex), flush=True)
    if os.path.isdir(td):
        keep = {os.path.splitext(f)[0] for f in imgs}
        for f in os.listdir(td):
            if os.path.splitext(f)[0] not in keep or f.endswith(".tmp"):
                try:
                    os.remove(os.path.join(td, f))
                except Exception:
                    pass
    return n, Image is not None


def _sdrlog_collect_meteor(self, sp):
    try:
        _sdrlog_orig_collect_meteor(self, sp)
    finally:
        try:
            n, pil = sdrlog_thumbs(self.base)
            st = load_json(p("meteor_state.json", self.base), {}) or {}
            ps = (st.get("passes") or [{}])[-1]
            k = len(ps.get("images") or [])
            tx = "Meteor-Überflug %s%s: %s" % (str(ps.get("sat") or "?"), (" max %d°" % round(ps["max_el"])) if isinstance(ps.get("max_el"), (int, float)) else "",
                                             ("%d Bild(er)" % k) if k else (ps.get("note") or "keine Bilder"))
            with _SDRLOG_LOCK:
                sdrlog_get(self.base).add("meteor", "meteor", tx + ("" if pil is not False else " · ohne Vorschaubild (PIL fehlt)"), time.time(), None, "ok" if k else "gelb")
        except Exception as ex:
            print("sdrLog Meteor:", ex, flush=True)


StateBC.on_dab = _sdrlog_on_dab
Planner.want = _sdrlog_want
Planner.sub_done = _sdrlog_sub_done
Planner.cal_finish = _sdrlog_cal_finish
Planner.collect_meteor = _sdrlog_collect_meteor
if __name__ == "__main__" and sys.argv[1:2] == ["run"]:
    try:
        import PIL as _sdrlog_pil
        _sdrlog_pv = "PIL %s" % getattr(_sdrlog_pil, "__version__", "?")
    except Exception:
        _sdrlog_pv = "ohne PIL - Seite zeigt Originalbilder"
    print("sdrLog aktiv: Technik-Verlauf %s (+ archive/techlog/), DAB-Verlauf ohne Programm-Infos (gezaehlt), Meteor-Vorschaubilder %d px (%s)" % (
        SDRLOG_FILE, SDRLOG_THUMB_W, _sdrlog_pv), flush=True)


def selftest_sdrlog():
    import tempfile
    tmp = tempfile.mkdtemp()
    # 1) DAB-Verlauf ohne Musiktitel, Zaehler je Sender
    assert sdrlog_keep_dls("11D", "BR24", False, "dls") and sdrlog_keep_dls("5C", "ASA DE", False, "dls") and sdrlog_keep_dls("11D", "BAYERN 3", True, "dls")
    assert sdrlog_keep_dls("5C", "Dlf", False, "ann") and not sdrlog_keep_dls("11D", "BAYERN 3", False, "dls") and not sdrlog_keep_dls("5C", "ENERGY", False, "dls")

    class B:
        f = os.path.join(tmp, "broadcast_state.json")
    b = B()
    assert dabhist_note(b, "11D", "BAYERN 3", "Wonderwall - Oasis", False, 1000) is None
    assert dabhist_note(b, "11D", "BAYERN 3", "Pet Shop Boys", False, 1001) is None
    assert dabhist_note(b, "11D", "BR24", "Nachrichten", False, 1002)["src"] == "BR24"
    assert dabhist_note(b, "5C", "ENERGY", "Gefahrenmitteilung Waldbrand", True, 1003)["warn"]
    dh = b._dabhist
    dh.save(force=True)
    j = load_json(p(DABHIST_FILE, tmp))
    assert [x["src"] for x in j["ev"]] == ["BR24", "ENERGY"] and j["skip"] == {"11D|BAYERN 3": 2}, j
    assert DabHist(tmp).skip == {"11D|BAYERN 3": 2}
    # 2) Technik: Sync verloren erst nach 2 Pruefungen, wieder da sofort, Ensemble-ID, Masten, Teil-2-Ereignisse
    tl = TechLog(tmp)
    ok = {"rx": True, "ensemble": "Bayern", "demod": {"snr": 11.0, "ens_id": "0x10A1"}}
    bad = {"rx": False, "rx_why": "kein Sync: Ensemble leer"}
    fig = {"11D": {"tii_set": ["08/18"]}}
    tl.dab("11D", ok, fig, [], 100)
    assert [x["k"] for x in tl.ev] == ["mast_new"] and "erstmals" in tl.ev[0]["text"], tl.ev   # Start: kein Sync-Ereignis
    tl.dab("11D", bad, fig, [], 200)
    assert len(tl.ev) == 1                                                    # eine Pruefung ohne Sync = noch nicht verloren
    tl.dab("11D", bad, fig, [], 300)
    assert tl.ev[-1]["k"] == "sync_lost" and "2 Prüfungen" in tl.ev[-1]["text"], tl.ev[-1]
    tl.dab("11D", bad, fig, [], 400)
    assert tl.ev[-1]["k"] == "sync_lost" and len(tl.ev) == 2                  # nicht doppelt
    tl.dab("11D", dict(ok, demod={"snr": 9.5, "ens_id": "0x10A5"}), {"11D": {"tii_set": ["05/14"]}},
           [{"id": "T2:11D:fig09:500", "t": 500, "ch": "11D", "k": "fig09", "text": "DAB 11D FIG 0/9: ECC 0xE0"}, {"id": "x", "t": 500, "k": "tii", "text": "TII"}], 500)
    ks = [x["k"] for x in tl.ev]
    assert ks[2:] == ["sync_ok", "ens_id", "mast_new", "mast_lost", "fig09"], ks
    assert "0x10A1 -> 0x10A5" in tl.ev[3]["text"] and "SNR 9.5" in tl.ev[2]["text"] and tl.ev[-1]["ref"] == "T2:11D:fig09:500"
    assert tl.ev[0]["text"] == "DAB 11D Mast erstmals: Bamberg (Geisberg) · 08/18" and tl.ev[4]["text"].endswith(": Nürnberg (Fernmeldeturm Schweinau) · 05/14"), tl.ev   # Klarnamen
    assert tl.ev[5]["text"].endswith(": Bamberg (Geisberg) · 08/18") and tl._mast("11D", "00/18") == "unbekannt · 00/18" and tl._mast("11D", "x") == "unbekannt · x"
    tl.dab("11D", ok, {"11D": {"tii_set": ["05/14"]}}, [{"id": "T2:11D:fig09:500", "t": 500, "k": "fig09", "text": "x"}], 600)
    assert [x["k"] for x in tl.ev][-1] == "ens_id"                           # Teil-2-Ereignis nur einmal; ID zurueck = Wechsel
    tl.dab("5C", bad, {}, [], 700)
    assert tl.st["sync"]["5C"] is False and tl.ev[-1]["k"] == "ens_id"       # 5C erstmals ohne Sync: kein Ereignis
    # 3) Stick 2
    assert tl.stick(False, {}, False, False, 800) and len([x for x in tl.ev if x["cat"] == "stick"]) == 0
    tl.stick(True, {"src": "ASA", "why": "Echtalarm"}, False, True, 900)
    tl.stick(True, {}, True, True, 1000)
    tl.stick(True, {}, False, True, 1100)
    tl.stick(True, {}, True, True, 1200)
    tl.stick(False, {}, False, False, 1300)
    sk = [x["k"] for x in tl.ev if x["cat"] == "stick"]
    assert sk == ["takeover_on", "fb10c_on", "back5c", "fb10c_on", "takeover_off", "fb10c_off"], sk
    assert "Auslöser ASA: Echtalarm" in [x for x in tl.ev if x["k"] == "takeover_on"][0]["text"]
    tl.save()
    t2 = TechLog(tmp)
    assert t2.seq == tl.seq and t2.st["sync"]["11D"] is True and t2.st["to"] is False
    t2.dab("11D", bad, {}, [], 2000)
    t2.dab("11D", bad, {}, [], 2100)
    assert t2.ev[-1]["k"] == "sync_lost"                                      # Zustand ueber Neustart erhalten
    arch = os.path.join(tmp, "archive", "techlog")
    na = sum(1 for r, _, fs in os.walk(arch) for fn in fs for _ in open(os.path.join(r, fn)))
    assert na == len(t2.ev), (na, len(t2.ev))
    t2.quiet = True
    for i in range(SDRLOG_MAX + 3):
        t2.add("x", "tech", "t%d" % i, 3000, save=False)
    assert len(t2.ev) == SDRLOG_MAX
    # 4) Planer-Haken: Stick-2-Watcher nur Rolle rot, Kalibrierung, Meteor
    tmp2 = tempfile.mkdtemp()

    class P:
        pass
    pl = P()
    pl.base, pl.role, pl.main, pl.stickno = tmp2, "rot", None, 2
    pl.t2 = True
    write_json(p(T2_TAKEOVER, tmp2), {"on": True, "since": 5, "src": "Knopf", "why": "Test"})
    _sdrlog_watch(pl, 10)
    assert sdrlog_get(tmp2).st.get("to") is True and not sdrlog_get(tmp2).ev    # erster Blick: nur Zustand
    pl._t4 = {"fb": True}
    _sdrlog_watch(pl, 12)
    assert not sdrlog_get(tmp2).ev                                              # hoechstens alle 5 s
    _sdrlog_watch(pl, 20)
    assert [x["k"] for x in sdrlog_get(tmp2).ev] == ["fb10c_on"]
    pl.role = "bc"
    pl._t4 = {"fb": False}
    _sdrlog_watch(pl, 40)
    assert len(sdrlog_get(tmp2).ev) == 1
    # Meteor: Vorschaubild + Ereignis (ohne Netz/Prozess, eigenes Bild)
    md = os.path.join(tmp2, "meteor")
    os.makedirs(md)
    try:
        from PIL import Image
        Image.new("RGB", (1600, 1200), (10, 20, 30)).save(os.path.join(md, "20261017-1200_M23_rgb.jpg"), "JPEG")
        pil = True
    except Exception:
        open(os.path.join(md, "20261017-1200_M23_rgb.jpg"), "wb").write(b"x")
        pil = False
    n, has = sdrlog_thumbs(tmp2)
    assert has is pil and n == (1 if pil else 0), (n, has, pil)
    if pil:
        im = Image.open(os.path.join(md, "thumbs", "20261017-1200_M23_rgb.jpg"))
        assert im.width == SDRLOG_THUMB_W and im.height == 360, im.size
        os.remove(os.path.join(md, "20261017-1200_M23_rgb.jpg"))
        assert sdrlog_thumbs(tmp2)[0] == 0 and not os.listdir(os.path.join(md, "thumbs"))   # verwaist -> weg
    write_json(p("meteor_state.json", tmp2), {"passes": [{"sat": "METEOR-M2 3", "max_el": 44.6, "images": ["a.jpg", "b.jpg"]}]})
    pl.collect_calls = 0
    _sdrlog_orig_cm = globals()["_sdrlog_orig_collect_meteor"]
    try:
        globals()["_sdrlog_orig_collect_meteor"] = lambda s, sp: setattr(s, "collect_calls", s.collect_calls + 1)
        _sdrlog_collect_meteor(pl, {})
    finally:
        globals()["_sdrlog_orig_collect_meteor"] = _sdrlog_orig_cm
    m = sdrlog_get(tmp2).ev[-1]
    assert pl.collect_calls == 1 and m["k"] == "meteor" and "METEOR-M2 3 max 45°: 2 Bild(er)" in m["text"], m
    # Kalibrierung
    pl.cfg = {"ppm_cal": {"try_t": 50, "t": 50, "ppm": 1.5, "ch": "11D", "note": "2 Messungen"}, "ppm": 2}
    _sdrlog_orig_cf = globals()["_sdrlog_orig_cal_finish"]
    try:
        globals()["_sdrlog_orig_cal_finish"] = lambda s, now: None
        _sdrlog_cal_finish(pl, 50)
        pl.cfg["ppm_cal"] = {"try_t": 60, "ch": "11D", "note": "zu wenig Proben"}
        _sdrlog_cal_finish(pl, 60)
    finally:
        globals()["_sdrlog_orig_cal_finish"] = _sdrlog_orig_cf
    c = [x["text"] for x in sdrlog_get(tmp2).ev if x["k"] == "cal"]
    assert c[0].startswith("Kalibrierung Stick 2 (11D): +1.50 ppm") and "kein Ergebnis (zu wenig Proben)" in c[1], c
    assert StateBC.on_dab is _sdrlog_on_dab and Planner.want is _sdrlog_want and Planner.collect_meteor is _sdrlog_collect_meteor
    _SDRLOG.pop(tmp2, None)
    print("selftest sdrLog ok (DAB-Verlauf ohne Musik + Zaehler, Sync verloren nach 2/wieder da, Ensemble-ID, Masten gesehen/weg, FIG 0/9 einmal, Stick-2-Uebernahme/Rueckfall 10C/zurueck 5C, Zustand ueber Neustart, Archiv, Kalibrierung, Meteor + Vorschaubild PIL=%s)" % pil, flush=True)
    return True
# ===== /sdrLog =====
FUB_EOF
EXPECT_G="22bb9aff0f1ca99fc4df54c5ce948d493c09de8525162c426c44043d567f07b5"
cat > "$W/guard_fu.py" << 'FUG_EOF'
"""AST-Guard fuer sdrLog / funkUI. Aufruf: guard_fu.py NAME EDITS  ART ALT NEU BLOCK ...  (ART = sm | sdr | dash) -> 0 ok, 1 Verstoss.
Ruecktausch (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben (schon eingespielt: nur Struktur).
Neue Bloecke/Stellen: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine neuen Faeden.
dashboard: nur GET-Routen /meteor/thumb/<name> (neu) und /dabhist (Ersatz), sonst nur Ansichten ersetzt; prepper_sdr: nur PIL fuer Vorschaubilder."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
label = sys.argv[1]
g = {}
exec(compile(rd(sys.argv[2]), "edits", "exec"), g)
OKMOD = {"sm": {"os", "time", "json", "tempfile", "sqlite3"}, "dash": {"os", "re", "time", "json", "html", "flask"},
         "sdr": {"os", "time", "json", "re", "tempfile", "PIL"}}
ROUTES = {"/meteor/thumb/<name>", "/dabhist"}
err, new_code = [], []
a = sys.argv[3:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    done = old == new and B.splitlines()[0] in old
    if new.count(B) != 1:
        err.append("%s: Block %s fehlt oder doppelt" % (kind, label))
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1) if kind != "dash" else new.replace(B, "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block %s" % (kind, len(E), label))
    new_code.append((kind, "Block", B))
    for o, n in E:
        ol = set(o.splitlines())
        new_code.append((kind, "Stelle", "\n".join(x for x in n.splitlines() if x not in ol)))
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode")
for kind, what, code in new_code:
    name = "%s %s" % (kind, what)
    if what != "Block":
        low = code.lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread"):
            if k in low:
                err.append("%s: %s" % (name, k))
        continue
    try:
        t = ast.parse(code)
    except SyntaxError as e:
        err.append("%s: Syntax %s" % (name, e)); continue
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                full = getattr(n, "module", None) or x.name
                mod = full.split(".")[0]
                if mod not in OKMOD[kind]:
                    err.append("%s: Import %s" % (name, mod))
                if mod == "flask" and x.name not in ("request", "send_from_directory", "abort"):
                    err.append("%s: flask.%s" % (name, x.name))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s: shell" % name)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if nm == "add_url_rule" and kind == "dash":
                kw = {k.arg: k.value for k in n.keywords}
                rule = getattr(n.args[0], "value", None) if n.args else None
                meth = kw.get("methods")
                if rule not in ROUTES or not (isinstance(meth, ast.List) and [getattr(x, "value", None) for x in meth.elts] == ["GET"]):
                    err.append("%s: Route %s" % (name, rule))
                continue
            if nm == "send_from_directory" and kind == "dash":
                continue
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer") \
                    or base in ("subprocess", "requests", "socket", "multiprocessing"):
                err.append("%s: Aufruf %s" % (name, nm))
        if kind == "dash" and isinstance(n, ast.Subscript) and isinstance(n.value, ast.Attribute) and n.value.attr == "view_functions" and isinstance(n.ctx, ast.Store):
            k = getattr(n.slice, "value", None)
            if k not in ("dh_page", "sdrp_meteor"):
                err.append("%s: Ansicht %s ersetzt" % (name, k))
    if kind == "dash":
        jsv = [n.value.value for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "_FU_JS" and isinstance(n.value, ast.Constant)]
        if len(jsv) != 1:
            err.append("%s: _FU_JS fehlt" % name)
        for js in ("method:", "XMLHttpRequest", "sendBeacon", "WebSocket", "localStorage"):
            if any(js in v for v in jsv):
                err.append("%s: JavaScript %s" % (name, js))
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard %s: nur die vorgesehenen Stellen + Block %s%s; keine Prozesse, kein Netz, kein shell, keine Faeden, keine Sendewege%s" % (
    label, label, " (schon eingespielt)" if all(rd(a[i + 1]) == rd(a[i + 2]) for i in range(0, len(a), 4)) else "",
    "; Dashboard nur GET /meteor/thumb + Ansichten /dabhist und /meteor ersetzt, eigene JS ohne POST" if "dash" in a[0::4] else "; prepper_sdr nur PIL fuer Vorschaubilder"))
FUG_EOF
EXPECT_CK="3a6213106b1d299dbce29f237b13cdcb255661460a7d12f15c5d6455bc06cc87"
cat > "$W/sqlccheck.py" << 'FUC_EOF'
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
FUC_EOF
EXPECT_FC="d570fbd0611aa288a86ac193f77a931efc373d5b1a2ce779416b2a06c9d446ba"
cat > "$W/fucheck.py" << 'FUF_EOF'
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
FUF_EOF
PF="$W/patch-fu.py"; ED="$W/sl_edits.py"; BL="$W/sl_sdr_block.py"; SG="$W/guard_fu.py"; CK="$W/sqlccheck.py"; FC="$W/fucheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_ED $ED" "$EXPECT_BL $BL" "$EXPECT_G $SG" "$EXPECT_CK $CK" "$EXPECT_FC $FC"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ -n "${4:-}" && "$1" == "$4" ]] && echo "bekannt ($5)" || echo "neu, Erkennung ueber Stellen/Guards"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sqlC" "$KNOWN_SDR16N" "sdrLog schon drin"))"
echo "dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sqlC" "$KNOWN_D16F" "funkUI")) - bleibt unveraendert"
echo "sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sqlC" "$KNOWN_SM16F" "funkUI")) - bleibt unveraendert"
echo "database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "sqlC")) - bleibt unveraendert"
echo "mesh_router.py sha16 $MR16 ($(wc -l < "$MR") Zeilen, $(kn "$MR16" "$KNOWN_MR16" "Teil 3")) - bleibt unveraendert"
echo "lagegeo.py sha16 $LG16 ($(kn "$LG16" "$KNOWN_LG16" "lageGeo")) - bleibt unveraendert"
grep -q '# ===== sqlC:' "$M" || { echo "STOP: sqlC fehlt in prepper_sdr.py - bitte zuerst apply-sqlc.sh, nichts geaendert"; exit 1; }
grep -q '# ===== sqlC:' "$F" || { echo "STOP: sqlC fehlt in dashboard.py - nichts geaendert"; exit 1; }
grep -q 'def selftest_sqlc' "$SMF" || { echo "STOP: sqlC fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
python3 "$PF" sdrLog sdr "$M" "$W/work/prepper_sdr.py" "$BL" "$ED" > "$W/p.log" || { cat "$W/p.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $SDR16) - nichts geaendert"; exit 1; }
N16=$(s16 "$W/work/prepper_sdr.py")
echo "OK Basis erkannt: $(cat "$W/p.log"); Ergebnis sha16 $N16 ($([[ "$N16" == "$KNOWN_SDR16N" ]] && echo "wie erwartet" || echo "abweichend von $KNOWN_SDR16N, Basis war neu - Guards entscheiden"))"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
python3 "$PF" sdrLog sdr "$W/work/prepper_sdr.py" "$W/work/x.py" "$BL" "$ED" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/x.py" || { echo "STOP: prepper_sdr nicht idempotent - nichts geaendert"; exit 1; }
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  "$py" -W error -m py_compile "$W/work/prepper_sdr.py" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile prepper_sdr.py ($py) - nichts geaendert"; exit 1; }
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$SMF" "$MR" "$W/work/prepper_sdr.py" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttest prepper_sdr mit $py (Sandbox, Test-Dateien, Fake-Prozesse, nichts gesendet): $(grep -F 'selftest sdrLog ok' "$W/sdrt.log" | cut -c1-260)"
done
python3 "$SG" sdrLog "$ED" sdr "$M" "$W/work/prepper_sdr.py" "$BL" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
echo "Vorschaubilder (PIL) auf dem Pi:"
python3 "$FC" pil "$SPY" "$VPY"
echo "  prepper-sdr startet mit: $(systemctl show -p ExecStart --value prepper-sdr 2>/dev/null | grep -o 'path=[^ ;]*' | head -1 | cut -c6- || echo unbekannt)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
if cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK sdrLog schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sdrLog|Traceback" | tail -6 | cut -c1-200 || true
    [[ -f "$M.bak-sdrlog-$TS" ]] && cp -a "$M.bak-sdrlog-$TS" "$M.rb" && mv -f "$M.rb" "$M"
    sudo systemctl restart prepper-sdr.service || true
    for i in $(seq 1 60); do sleep 3; systemctl is-active --quiet prepper-sdr && break; done
    cmp -s "$M" "$M.bak-sdrlog-$TS" && echo "  prepper_sdr.py = Sicherung ($(s16 "$M"))" || echo "  WARNUNG prepper_sdr.py ungleich Sicherung"
    echo "  Sicherung lagezentrum.db von vorher: $LZ.bak-sdrlog-$TS (nicht zurueckgespielt, prepper_sdr schreibt nur wie vorher)"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  cp -a "$M" "$M.bak-sdrlog-$TS"
  { ls -1t "$M.bak-sdrlog-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sdrlog-$TS" \
      || { rm -f "$LZ.bak-sdrlog-$TS" "$M.bak-sdrlog-$TS"; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sdrlog-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-sdrlog-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (DB oder JSON, max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$CK" statusfresh "$DASH_DIR" "$T0" && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr ohne frischen Status"; exit 1; }
  echo "OK prepper-sdr laeuft, SDR-Status frisch (Dashboard nicht neu gestartet)"
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /dabhist /meteor /api/meteor /api/sdr/live /api/t4/status; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
grep -q "L\[6\].textContent=tr?(tr.line||'')" "$W/funk.html" && echo "OK /funk: SDR-Status-Daten wie vorher" || rbx "/funk ohne Zeile Datenquelle"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JS=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrLog aktiv|sqlC: Transport" | tail -3 || true)
if [[ "$JS" == *"sdrLog aktiv"* ]]; then echo "OK Journal prepper-sdr: $(echo "$JS" | grep 'sdrLog aktiv' | tail -1 | cut -c1-230)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "prepper-sdr meldet sdrLog nicht (Journal)"; fi
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrLog (speichern|dabHist|on_dab|Stick 2|Kalibrierung|Meteor):|sqlC: Fehler im Schreibfaden" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrLog-Fehler" || rbx "$E Traceback/sdrLog-Fehlerzeilen im Journal prepper-sdr"
python3 "$FC" techlog "$DASH_DIR" || true
for x in "$F:$D16" "$SMF:$SM16" "$DBF:$DB16" "$MR:$MR16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
echo "OK guards sdrLog(sdr)=$(grep -c '# ===== sdrLog:' "$M" || true) sqlC(sdr)=$(grep -c '# ===== sqlC:' "$M" || true) sqlB(sdr)=$(grep -c '# ===== sqlB:' "$M" || true) tiiFix2(sdr)=$(grep -c '# tiiFix2' "$M" || true) funkUI(dash)=$(grep -c '# ===== funkUI:' "$F" || true) funkUI(sdr_manager)=$(grep -c 'def selftest_funkui' "$SMF" || true) sqlC(dash)=$(grep -c '# ===== sqlC:' "$F" || true)"
[[ -f "$M.bak-sdrlog-$TS" ]] && echo "Backups: prepper_sdr.py.bak-sdrlog-$TS, lagezentrum.db.bak-sdrlog-$TS, behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: sudo cp -a $M.bak-sdrlog-$TS $M und sudo systemctl restart prepper-sdr"
echo "COMMIT $COMMIT_ARG sdrlog=1 fertig"
