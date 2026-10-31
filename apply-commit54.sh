#!/bin/bash
set -eEuo pipefail
# commit54 qrmLage + evlFix + qrmRun - QRM-Messung laeuft wieder, Ereignislog ohne Geister (nur lokal, sendet nichts):
#  C) prepper_sdr.py: manuell AUS gestellte QRM-Messung (Lage-Schalter, ausser Profil Ruhe) gilt hoechstens 6 h, auch nach Neustart;
#     abgelaufene Pause wird aus sdr_lage.json entfernt (Profil und andere Schalter bleiben). Waechter "QRM steht" (> 1 h ohne Messung)
#     nur in Status/API/Journal (kein Mesh, kein HB-Problem). Veraltete Werte grau statt rot. Planer-Zustand (letzte/naechste Messung, Grund) in /api/sdr/noise.
#  B) prepper_evlog.py: Ereignisse mit unplausiblem Start (vor Uhrsync und aelter als 24 h, Uhrsprung, Start in der Zukunft) werden verworfen
#     (Nebenarchiv sdr_events_verworfen.jsonl), Ende bei veralteter Messung = letzte Messung.
#  dashboard.py: Anzeige "grau - veraltet", "QRM steht" mit Grund und naechstem Versuch, naechste Messung.
#  Je Datei ein Block vor __main__ (+ je eine Selbsttest-Zeile in prepper_sdr.py/prepper_evlog.py). Alle drei alt -> ersetzen, alle neu -> nichts tun, gemischt -> STOP.
# Aufruf: bash /tmp/apply-commit54.sh commit54 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 832787ef1c3b44bc (nach commit53) / prepper_sdr.py 0900bfe6ba67e657 / prepper_evlog.py 5e16f710aba58f34, neu 7b81384b4af00883 / 264ef34996e17753 / 8bffd396972b60fa;
#   lage_pages.py a51d9b51a646813d (bleibt unveraendert). Stand vor commit53 -> STOP "erst commit53 anwenden".
# Sicherungen DATEI.bak-commit54-ZEIT fuer dashboard.py, prepper_sdr.py, prepper_evlog.py, sdr_events.json, sdr_lage.json (je letzte 3).
# Keine Datenbank-Aenderung. Neu gestartet werden prepper-sdr und prepper-dashboard. Beim Einspielen wird nichts gesendet, Gain-Stufe 16 bleibt.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FS="$DASH_DIR/prepper_sdr.py"
FE="$DASH_DIR/prepper_evlog.py"
DEV="$DASH_DIR/sdr_events.json"
DLA="$DASH_DIR/sdr_lage.json"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit54-apply
KEEP_LAST=3
NM=commit54
KNOWN_D16="832787ef1c3b44bc"; KNOWN_D16N="7b81384b4af00883"; KNOWN_D16_C52="ab18872053f58871"; KNOWN_D16_C51="67d58079139cd373"; KNOWN_D16_C50="2a3625a3325653b1"
KNOWN_S16="0900bfe6ba67e657"; KNOWN_S16N="264ef34996e17753"; KNOWN_E16="5e16f710aba58f34"; KNOWN_E16N="8bffd396972b60fa"
KNOWN_L16="a51d9b51a646813d"; KNOWN_L16_C52="1d33ae9fd78f53dc"
MEAS_WAIT=1200
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
SIM=0; [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && SIM=1
[[ "$SIM" == 1 && -n "${C54_MEAS_WAIT:-}" ]] && MEAS_WAIT="$C54_MEAS_WAIT"
echo "=== commit54 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): qrmLage + evlFix + qrmRun, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/G"
EXPECT_PAT="1e70c6ab43f15061917e1fd3816ca12e699a3c2dc1b4a0eadb250dc3c03120c1"
cat > "$W/patch.py" << 'MK_C54_PAT_EOF'
"""Patcher commit54 (generisch wie relStop). Aufruf: patch.py NAME dsh|sdr|evl QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
name = {"dsh": "dashboard.py", "sdr": "prepper_sdr.py", "evl": "prepper_evlog.py"}[kind]
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
MK_C54_PAT_EOF
EXPECT_EDI="d65472449180139af2bfaea52f9821dc442962ccf7336b9a9d88f82ee52a859f"
cat > "$W/edits.py" << 'MK_C54_EDI_EOF'
"""Stellen commit54: je Datei ein Block vor __main__ plus eine Selbsttest-Zeile (prepper_sdr.py, prepper_evlog.py)."""
_A = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
DSH_ANCHOR = _A
SDR_EDITS = [("        print(selftest_sdrstick3e(), flush=True)\n",
              "        print(selftest_sdrstick3e(), flush=True)\n        print(selftest_qrmlage(), flush=True)\n")]
SDR_ANCHOR = _A
EVL_EDITS = [('    elif len(argv) >= 2 and argv[1] == "selftest":\n        selftest()\n',
              '    elif len(argv) >= 2 and argv[1] == "selftest":\n        selftest()\n        print(selftest_evlfix(), flush=True)\n')]
EVL_ANCHOR = _A
MK_C54_EDI_EOF
EXPECT_BDS="45d26e537f346e232981fe5294465c276cef7c2a643b56f9159e88e247325563"
cat > "$W/G/blk_dsh.py" << 'MK_C54_BDS_EOF'
# ===== qrmRun: Anzeige QRM-Planer-Zustand (commit54) - veraltete Werte grau "veraltet" statt rot, "QRM steht" mit Grund und naechstem Versuch, naechste Messung; Daten aus prepper-sdr (noise.run); nur Anzeige, sendet nichts =====
QR_MARK = "/* qrmRun */"
_QR_SDRN_EDITS = [
    (r"""function ufStale(){var N=D.noise||{};return !N.t||(ufNow()-N.t)>UF_F*(D.iv||900);}""",
     r"""function ufStale(){var N=D.noise||{};if(N.run&&typeof N.run.stale==='boolean')return N.run.stale;return !N.t||(ufNow()-N.t)>UF_F*(D.iv||900);}""" + QR_MARK),
    (r"""var N=D.noise||{},U=D.uf||{};return 'keine Kurve – '""",
     r"""var N=D.noise||{},U={skip:(N.run||{}).why||(D.uf||{}).skip};return 'keine Kurve – '"""),
    (r"""function ufLast(N){var o=ufStale();var x=el('div','small'+(o?' uf-old':''),'Messung alle '+Math.round((D.iv||900)/60)+' min'+(N.t?' · zuletzt '+dm(N.t)+(o?' (vor '+ufAge(N.t)+' – läuft nicht)':''):' · noch keine Messung'));return x;}""",
     r"""function ufLast(N){var o=ufStale(),R=N.run||{};var x=el('div','small'+(o?' uf-old':''),(o?'QRM steht – ':'')+'Messung alle '+Math.round((R.iv||D.iv||900)/60)+' min'+(N.t?' · zuletzt '+dm(N.t)+(o?' (vor '+ufAge(N.t)+')':''):' · noch keine Messung')+(o&&R.why?' · Grund: '+R.why:'')+(R.next?(o?' · nächster Versuch ':' · nächste ')+hm(R.next):(o?' · kein Termin geplant':'')));return x;}"""),
    (r"""grau:'noch keine Messung'}[q]||q)""",
     r"""grau:(N.t&&ufStale()?'grau – veraltet (letzte Messung vor '+ufAge(N.t)+')':'noch keine Messung')}[q]||q)"""),
]


def _qr_apply(js, edits, tag):
    """Alle Stellen genau einmal, sonst Fehler (nichts halb)."""
    for i, (o, n) in enumerate(edits):
        if js.count(o) != 1:
            raise ValueError("%s: Stelle %d nicht genau einmal (%d)" % (tag, i + 1, js.count(o)))
        js = js.replace(o, n, 1)
    return js


def _selftest_qrmrun():
    s = _qr_apply(_SDRN_JS, _QR_SDRN_EDITS, "Stoersender-Skript")
    assert s.count(QR_MARK) == 1 and "return N.run.stale;" in s and "grau – veraltet" in s and "QRM steht – " in s and "nächster Versuch" in s, "qrmRun Stellen"
    assert s.count("setInterval(") == 1, "Abruf doppelt"
    return s, "qrmRun ok (%d Stellen im Stoersender-Skript: veraltet grau, QRM steht mit Grund, naechste Messung; Daten noise.run aus prepper-sdr)" % len(_QR_SDRN_EDITS)


_qr_old = _SDRN_JS
try:
    if QR_MARK in _SDRN_JS:
        raise ValueError("doppelt geladen")
    if UF_MARK not in _SDRN_JS:
        raise ValueError("umweltFlach nicht aktiv")
    _qr_s, _QR_ST = _selftest_qrmrun()
    _SDRN_JS = _qr_s
    print("qrmRun aktiv: %s" % _QR_ST, flush=True)
except Exception as _qr_ex:
    _SDRN_JS = _qr_old
    print("qrmRun Selbsttest FEHLER (%s: %s)" % (type(_qr_ex).__name__, _qr_ex), flush=True)
# ===== /qrmRun =====
MK_C54_BDS_EOF
EXPECT_BSD="cba505e322406f3edc362ad31f0c771056285cb51c48ad8cdac39df95f024059"
cat > "$W/G/blk_sdr.py" << 'MK_C54_BSD_EOF'
# ===== qrmLage: QRM-Pause in der Lage laeuft ab (max. 6 h, auch nach Neustart), Lage-Datei wird bereinigt; Waechter "QRM steht" (> 1 h ohne Messung) mit Planer-Zustand in Status/API, veraltete Werte grau statt rot; keine Mesh-/HB-Meldung =====
QRL_PAUSE_MAX_S = 6 * 3600      # manuell AUS gestellte QRM-Messung (ausser Profil Ruhe) gilt hoechstens so lange
QRL_STALE_S = 3600              # laenger ohne Messung = "QRM steht", Werte gelten als veraltet (grau)
QRL_HEAL_EVERY_S = 60
_qrl_orig_get_lage = get_lage
_qrl_orig_set_lage = set_lage


def _qrl_pause(d, sw, prof, now):
    """Info zur QRM-Pause: None = keine manuelle Pause; sonst dict mit since/until/expired."""
    if sw.get("noise") != "aus" or LAGE_PROFILES[prof].get("noise") == "aus":
        return None
    t0 = d.get("noise_off_at") if isinstance(d.get("noise_off_at"), (int, float)) else d.get("at")
    t0 = t0 if isinstance(t0, (int, float)) and not isinstance(t0, bool) else None
    exp = t0 is None or now - t0 > QRL_PAUSE_MAX_S or now < t0 - 60
    return {"since": t0, "until": int(t0 + QRL_PAUSE_MAX_S) if t0 is not None else None, "expired": bool(exp)}


def get_lage(base=None, now=None):
    """Wie bisher, aber eine manuelle QRM-Pause (Schalter AUS, Profil ist nicht Ruhe) gilt hoechstens QRL_PAUSE_MAX_S;
    danach wirkt wieder der Profil-Standard - auch nach Neustart (Zeitstempel steht in der Datei)."""
    r = _qrl_orig_get_lage(base)
    try:
        now = time.time() if now is None else now
        d = load_json(p("sdr_lage.json", base), {}) or {}
        prof = r["profile"]
        pz = _qrl_pause(d, r["sw"], prof, now)
        if pz:
            r["qrm_pause"] = pz
            if pz["expired"]:
                sw = dict(r["sw"])
                sw["noise"] = LAGE_PROFILES[prof]["noise"]
                r["sw"], r["custom"] = sw, sw != LAGE_PROFILES[prof]
    except Exception as ex:
        print("qrmLage get_lage:", ex, flush=True)
    return r


def set_lage(base, profile=None, src=None, state=None):
    """Wie bisher; beim Ausschalten der QRM-Messung wird der Zeitpunkt gemerkt (Pause laeuft nach QRL_PAUSE_MAX_S ab)."""
    try:
        old = load_json(p("sdr_lage.json", base), {}) or {}
        old_off = old.get("noise_off_at") if isinstance(old, dict) else None
    except Exception:
        old_off = None
    r = _qrl_orig_set_lage(base, profile=profile, src=src, state=state)
    try:
        if r["sw"].get("noise") == "aus" and LAGE_PROFILES[r["profile"]].get("noise") != "aus":
            d = load_json(p("sdr_lage.json", base), {}) or {}
            keep = profile is None and src != "noise" and isinstance(old_off, (int, float))
            d["noise_off_at"] = int(old_off) if keep else int(time.time())   # anderer Schalter: Pause-Beginn bleibt
            write_json(p("sdr_lage.json", base), d)
            r = get_lage(base)
    except Exception as ex:
        print("qrmLage set_lage:", ex, flush=True)
    return r


def qrl_heal(base, now=None, log=None):
    """Abgelaufene QRM-Pause aus sdr_lage.json entfernen (Profil und andere Schalter bleiben). True = Datei bereinigt."""
    now = time.time() if now is None else now
    d = load_json(p("sdr_lage.json", base), {}) or {}
    if not isinstance(d, dict) or d.get("profile") not in LAGE_PROFILES or not isinstance(d.get("sw"), dict):
        return False
    prof = d["profile"]
    sw = dict(d["sw"])
    pz = _qrl_pause(d, dict(LAGE_PROFILES[prof], **{k: v for k, v in sw.items() if k in LAGE_SRC and v in LAGE_STATES}), prof, now)
    if not pz or not pz["expired"]:
        return False
    sw["noise"] = LAGE_PROFILES[prof]["noise"]
    n = dict(d)
    n["sw"] = sw
    n.pop("noise_off_at", None)
    n["noise_heal_at"] = int(now)
    n["noise_heal_was"] = {"since": pz["since"], "max_s": QRL_PAUSE_MAX_S}
    write_json(p("sdr_lage.json", base), n)
    if log:
        log("qrmLage: QRM-Messung war in der %s seit %s AUS - Pause abgelaufen (max. %d h), Messung wieder %s; Profil und andere Schalter unveraendert" % (
            LAGE_NAMES[prof], time.strftime("%d.%m. %H:%M", time.localtime(pz["since"])) if pz["since"] else "?", QRL_PAUSE_MAX_S // 3600, sw["noise"].upper()))
    return True


_qrl_orig_lage_apply = Planner.lage_apply


def _qrl_lage_apply(self):
    if getattr(self, "main", None) is None:
        now = time.time()
        if now - self.__dict__.get("_qrl_heal_t", 0) >= QRL_HEAL_EVERY_S or now < self.__dict__.get("_qrl_heal_t", 0):
            self.__dict__["_qrl_heal_t"] = now
            try:
                qrl_heal(self.base, now, self.log)
            except Exception as ex:
                self.log("qrmLage:", ex)
    return _qrl_orig_lage_apply(self)


def _qrl_planners(m):
    hb = [h for h in (m.__dict__.get("hobbies") or []) if h is not None]
    hb.sort(key=lambda h: getattr(h, "stickno", 9))
    ps = hb[:1] + ([m.worker] if getattr(m, "worker", None) is not None else []) + [m] + hb[1:]
    return ps


def qrl_run(m, now=None):
    """Planer-Zustand der QRM-Messung (fuer Status/API): letzte/naechste Messung, Grund, messender Planer, steht/veraltet."""
    now = time.time() if now is None else now
    t = (m.snoise.d or {}).get("t")
    t = t if isinstance(t, (int, float)) and not isinstance(t, bool) else None
    age = int(now - t) if t else None
    meas, nxt, iv = [], None, None
    for pl in _qrl_planners(m):
        try:
            q = pl.noise_queue()
        except Exception:
            q = []
        if q:
            niv = float(pl.cfg.get("noise_interval_s") or 900)
            n = int(pl.last_noise + niv)
            meas.append(pl)
            if nxt is None or n < nxt:
                nxt, iv = n, int(niv)
    why = None
    if meas:
        pl = meas[0]
        sp = pl.special if isinstance(getattr(pl, "special", None), dict) else None
        if sp and sp.get("kind") == "noise":
            why = "Messung laeuft gerade"
        else:
            sk, skt = (pl.ndiag or {}).get("skip"), (pl.ndiag or {}).get("skip_t")
            if sk and skt and now - skt < 2 * (iv or 900):
                why = sk
        try:
            md = get_mode(m.base)
            if md.get("mode") != "auto":
                why = "Betriebsart %s - QRM-Messung nur in Automatik" % md.get("mode")
        except Exception:
            pass
        name = pl
    else:
        name = next((x for x in _qrl_planners(m) if not x.cfg.get("dev_kind") == "airspy"), m)
        try:
            why = name.noise_why_off()
        except Exception as ex:
            why = "unbekannt (%s)" % ex
    try:
        pn = air_name(name.stickno) if name is not m or name.stickno != 1 else "Stick 1"
    except Exception:
        pn = "Stick %s" % getattr(name, "stickno", "?")
    stale = t is None or age > QRL_STALE_S
    lz = getattr(m, "lage", None) or {}
    return {"last": int(t) if t else None, "age_s": age, "next": nxt, "iv": iv, "why": why, "planner": pn, "on": bool(meas),
            "stale": bool(stale), "stale_after_s": QRL_STALE_S, "since": int(t) if (stale and t) else None, "pause": lz.get("qrm_pause"), "t": int(now)}


def _qrl_grey(r, run):
    """Veraltete Werte grau statt rot/gelb (Originalwert bleibt als lvl_alt sichtbar)."""
    ago = run.get("age_s")
    txt = "veraltet - letzte Messung vor %s" % (("%d h" % (ago // 3600)) if ago and ago >= 7200 else ("%d min" % (ago // 60)) if ago else "?") if run.get("last") else "noch keine Messung"
    for k in ("qrm", "thunder"):
        x = r.get(k)
        x = dict(x) if isinstance(x, dict) else {}
        if x.get("lvl") not in (None, "grau"):
            x["lvl_alt"] = x.get("lvl")
        x["lvl"], x["stale"], x["why_stale"] = "grau", True, txt
        x["trend"] = []
        r[k] = x
    bs = []
    for b in r.get("bands") or []:
        b = dict(b)
        if b.get("lvl") not in (None, "grau"):
            b["lvl_alt"] = b.get("lvl")
        b["lvl"], b["stale"], b["trend"], b["n_pers"] = "grau", True, None, 0
        bs.append(b)
    r["bands"] = bs
    r["stale"] = True
    return r


_qrl_orig_nsum = Planner.noise_summary


def _qrl_nsum(self):
    r = _qrl_orig_nsum(self)
    try:
        m = self if getattr(self, "main", None) is None else self.main
        now = time.time()
        run = qrl_run(m, now)
        r["run"] = run
        if self is m:
            r["next"] = run["next"]
            w = bool(run["stale"])
            if w != m.__dict__.get("_qrl_w"):
                if w:
                    m.log("qrmRun: QRM steht - letzte Messung %s, Grund: %s (nur Anzeige, keine Mesh-Meldung)" % (
                        time.strftime("%d.%m. %H:%M", time.localtime(run["last"])) if run["last"] else "noch keine", run["why"] or "?"))
                elif m.__dict__.get("_qrl_w") is not None:
                    m.log("qrmRun: QRM-Messung laeuft wieder (%s)" % time.strftime("%d.%m. %H:%M", time.localtime(run["last"])))
                m.__dict__["_qrl_w"] = w
        if run["stale"]:
            _qrl_grey(r, run)
    except Exception as ex:
        print("qrmRun noise_summary:", ex, flush=True)
    return r


Planner.lage_apply = _qrl_lage_apply
Planner.noise_summary = _qrl_nsum


def selftest_qrmlage():
    import tempfile
    d = tempfile.mkdtemp(prefix="qrl")
    t0 = time.time()
    # 1) Warnlage mit QRM AUS seit 13 d (alte Datei ohne noise_off_at) -> wirkt als AN, Heal bereinigt Datei
    write_json(p("sdr_lage.json", d), {"profile": "warn", "sw": dict(LAGE_PROFILES["warn"], noise="aus", meteor="an"), "at": int(t0 - 13 * 86400)})
    g = get_lage(d)
    assert g["sw"]["noise"] == "an" and g["qrm_pause"]["expired"] and g["profile"] == "warn" and g["sw"]["meteor"] == "an", g
    lg = []
    assert qrl_heal(d, t0, lambda *a: lg.append(" ".join(str(x) for x in a))) is True and lg and "Pause abgelaufen" in lg[0]
    f = load_json(p("sdr_lage.json", d), {})
    assert f["sw"]["noise"] == "an" and f["sw"]["meteor"] == "an" and f["profile"] == "warn" and f["at"] == int(t0 - 13 * 86400) and f["noise_heal_at"] == int(t0), f
    assert qrl_heal(d, t0 + 5) is False                       # idempotent
    g = get_lage(d)
    assert g["sw"]["noise"] == "an" and "qrm_pause" not in g and g["custom"] and g["sw"]["meteor"] == "an", g
    # 2) frische Pause gilt, nach 6 h nicht mehr; auch nach "Neustart" (nur Datei)
    r = set_lage(d, src="noise", state="aus")
    assert r["sw"]["noise"] == "aus" and r["qrm_pause"] and not r["qrm_pause"]["expired"], r
    f = load_json(p("sdr_lage.json", d), {})
    assert abs(f["noise_off_at"] - time.time()) < 5
    assert get_lage(d, now=time.time() + QRL_PAUSE_MAX_S - 60)["sw"]["noise"] == "aus"
    assert get_lage(d, now=time.time() + QRL_PAUSE_MAX_S + 60)["sw"]["noise"] == "an"
    assert get_lage(d, now=time.time() - 3600)["sw"]["noise"] == "an"     # Uhr rueckwaerts -> Pause gilt nicht
    assert qrl_heal(d, time.time() + 60) is False
    assert qrl_heal(d, time.time() + QRL_PAUSE_MAX_S + 60) is True
    # 3) Profil Ruhe (QRM aus ist Standard) bleibt unberuehrt; anderer Schalter setzt Zeit nicht neu
    set_lage(d, profile="ruhe")
    assert get_lage(d, now=time.time() + 30 * 86400)["sw"]["noise"] == "aus" and qrl_heal(d, time.time() + 30 * 86400) is False
    set_lage(d, profile="normal")
    set_lage(d, src="noise", state="aus")
    a0 = load_json(p("sdr_lage.json", d), {})["noise_off_at"]
    set_lage(d, src="433", state="an")
    a1 = load_json(p("sdr_lage.json", d), {})
    assert a1["noise_off_at"] == a0 and a1["sw"]["noise"] == "aus" and a1["sw"]["433"] == "an", a1
    assert get_lage(d, now=a0 + QRL_PAUSE_MAX_S + 1)["sw"]["noise"] == "auto"
    set_lage(d, src="noise", state="an")
    assert get_lage(d, now=time.time() + 86400 * 9)["sw"]["noise"] == "an" and "qrm_pause" not in get_lage(d)
    # 4) kaputte/fehlende Datei = Normal, kein Heal
    with open(p("sdr_lage.json", d), "w") as fh:
        fh.write("{kaputt")
    assert get_lage(d)["profile"] == "normal" and qrl_heal(d) is False

    # 5) Lauf-Zustand / Waechter / grau
    class N:
        pass

    class Pl:
        def __init__(s, no, q, last, kind="rtl"):
            s.stickno, s._q, s.last_noise, s.cfg, s.ndiag, s.special, s.main = no, q, last, {"noise_interval_s": 600, "dev_kind": kind, "noise_enable": bool(q)}, {}, None, None
            s.lage = {"name": "Warnlage", "sw": {"noise": "aus" if not q else "an"}}

        def noise_queue(s):
            return s._q

        def noise_why_off(s):
            return Planner.noise_why_off(s)
    lg = []
    m = Pl(1, [], 0, "airspy")
    m.base, m.worker, m.snoise = d, None, N()
    m.log = lambda *a: lg.append(" ".join(str(x) for x in a))
    h3 = Pl(3, [("nz:0", 60)], t0 - 300)
    h3.main = m
    m.__dict__["hobbies"] = [Pl(4, [], 0), h3]
    write_json(p("sdr_mode.json", d), {"mode": "auto"})
    m.snoise.d = {"t": t0 - 13 * 86400, "qrm": {"lvl": "rot", "t": t0 - 13 * 86400, "trend": ["n2m"]}, "thunder": {"lvl": "gelb"},
                  "bands": {"n2m": {"ok": True, "lvl": "rot", "t": t0 - 13 * 86400, "n_pers": 2, "cars": [1], "trend": {"on": True}}}}
    m.cfg["noise_enable"] = False
    m.__dict__["lage"] = {"qrm_pause": None}
    run = qrl_run(m, t0)
    assert run["stale"] and run["next"] == int(t0 + 300) and run["on"] and run["planner"] and run["age_s"] >= 13 * 86400 - 5 and run["since"], run
    m.noise_summary = lambda: _qrl_nsum(m)
    _qrl_orig = globals()["_qrl_orig_nsum"]
    try:
        globals()["_qrl_orig_nsum"] = lambda s: {"t": s.snoise.d["t"], "qrm": dict(s.snoise.d["qrm"]), "thunder": dict(s.snoise.d["thunder"]),
                                                  "bands": [{"id": "n2m", "lvl": "rot", "ok": True, "n_pers": 2, "trend": {"on": True}}], "next": None}
        r = _qrl_nsum(m)
        assert r["qrm"]["lvl"] == "grau" and r["qrm"]["lvl_alt"] == "rot" and r["thunder"]["lvl"] == "grau" and r["bands"][0]["lvl"] == "grau", r
        assert r["bands"][0]["n_pers"] == 0 and r["bands"][0]["trend"] is None and r["qrm"]["trend"] == [] and "veraltet" in r["qrm"]["why_stale"], r
        assert r["next"] == int(t0 + 300) and r["run"]["stale"] and len(lg) == 1 and "QRM steht" in lg[0], (r, lg)
        _qrl_nsum(m)
        assert len(lg) == 1                                   # nur bei Wechsel
        m.snoise.d["t"] = time.time() - 60
        r = _qrl_nsum(m)
        assert r["qrm"]["lvl"] == "rot" and not r["run"]["stale"] and "stale" not in r and len(lg) == 2 and "laeuft wieder" in lg[1], (r, lg)
        # niemand misst -> Grund aus Lage
        h3._q = []
        h3.cfg["noise_enable"] = False
        h3.lage = {"name": "Warnlage", "sw": {"noise": "aus"}}
        m.snoise.d["t"] = t0 - 7200
        run = qrl_run(m, time.time())
        assert run["stale"] and not run["on"] and run["next"] is None and run["why"] == "Messung AUS (Lage Warnlage)", run
        write_json(p("sdr_mode.json", d), {"mode": "433"})
        h3._q = [("nz:0", 60)]
        assert "Betriebsart 433" in qrl_run(m, time.time())["why"]
    finally:
        globals()["_qrl_orig_nsum"] = _qrl_orig
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    return "selftest qrmLage ok (QRM-Pause max. %d h auch nach Neustart, Datei-Heilung idempotent, Ruhe unberuehrt, Planer-Zustand next/why/stale, Waechter nur Journal, veraltet = grau)" % (QRL_PAUSE_MAX_S // 3600)
# ===== /qrmLage =====


MK_C54_BSD_EOF
EXPECT_BEV="b2ce0b1af0e03333935f4fd250bf4a68fd486361562e676ea2aa904a1658a672"
cat > "$W/G/blk_evl.py" << 'MK_C54_BEV_EOF'
# ===== evlFix: Ereignislog - Uhrsprung und Altersgrenze (commit54): Ereignisse mit unplausiblem Start (vor Uhrsync, Uhrsprung) werden verworfen statt ewig weiterzulaufen; Ende bei veralteter QRM-Messung = letzte Messung =====
EVF_GHOST_S = 86400     # Start ohne Uhrsync und aelter als 24 h, waehrend die Uhr jetzt synchron ist -> Start unplausibel
EVF_JUMP_S = 3600       # Abstand zwischen zwei Aufrufen > 1 h (vorwaerts) oder Uhr > 60 s rueckwaerts = Uhrsprung
EVF_BACK_S = 60
EVF_FUT_S = 600         # Start mehr als 10 min in der Zukunft = unplausibel
EVF_CHECK_S = 60
_evf_orig_init = EvLog.__init__
_evf_orig_update = EvLog.update


def _evf_sync(tq, now):
    try:
        return bool((tq.get(now) or {}).get("sync"))
    except Exception:
        return False


def _evf_bad(e, now, synced):
    """Grund, warum ein Ereignis unplausibel ist, sonst None."""
    st = e.get("start")
    if not _fin(st):
        return "Start fehlt"
    if st > now + EVF_FUT_S:
        return "Start in der Zukunft (Uhr zurueckgestellt)"
    if synced and not (e.get("start_tq") or {}).get("sync") and (e.get("end") if _fin(e.get("end")) else now) - st > EVF_GHOST_S:
        return "Start vor Uhrsync und aelter als %d h" % (EVF_GHOST_S // 3600)
    return None


def _evf_drop(self, now, why_fn, tag):
    """Offene/wartende Ereignisse und Ring nach why_fn pruefen; verworfene ins Nebenarchiv (nicht ins Ereignis-Archiv)."""
    out = []
    for nm in ("open", "pend"):
        dct = getattr(self, nm)
        for k in list(dct):
            w = why_fn(dct[k])
            if w:
                out.append((dict(dct.pop(k)), w))
    keep = []
    for x in self.last:
        w = why_fn(x) if _fin(x.get("start")) else None
        if w:
            out.append((dict(x), w))
        else:
            keep.append(x)
    self.last = keep
    if out:
        self.dirty = True
        try:
            for e, w in out:
                append_line(os.path.join(mon_dir(self.base, now), "sdr_events_verworfen.jsonl"), dict(e, verworfen=w, verworfen_t=int(now), verworfen_iso=iso(now)))
        except Exception as ex:
            self.log("evlFix Nebenarchiv:", ex)
        ex = out[0][0]
        self.log("evlFix: %d Ereignis(se) verworfen (%s; z. B. %s %s Start %s) - Uhrsprung/fehlende Altersgrenze, nichts gesendet" % (
            len(out), tag, ex.get("band"), ex.get("kind"), iso(ex["start"]) if _fin(ex.get("start")) else "?"))
    return len(out)


def _evf_jump(self, now, prev):
    """Uhrsprung: offene/wartende Ereignisse mit Start ohne Uhrsync oder Start nach jetzt verwerfen (Ring bleibt)."""
    ring, self.last = self.last, []
    try:
        why = "Uhrsprung %+d s (Start vor dem Sprung, ohne Uhrsync)" % int(now - prev)
        return _evf_drop(self, now, lambda e: why if (not (e.get("start_tq") or {}).get("sync") or e["start"] > now) else None, "Uhrsprung %+d s" % int(now - prev))
    finally:
        self.last = ring + self.last


def _evf_init(self, base, load_json, write_json, log=lambda *a: None, now=None, tq=None):
    _evf_orig_init(self, base, load_json, write_json, log, now, tq)
    now = int(now or time.time())
    syn = _evf_sync(self.tq, now)
    self.evf = {"t_prev": now, "chk": now, "dropped": 0, "jumps": 0}
    try:
        self.evf["dropped"] += _evf_drop(self, now, lambda e: _evf_bad(e, now, syn), "beim Start")
    except Exception as ex:
        self.log("evlFix Start:", ex)


def _evf_update(self, st, now=None):
    now = int(now or time.time())
    f = self.__dict__.setdefault("evf", {"t_prev": now, "chk": now, "dropped": 0, "jumps": 0})
    try:
        prev = f.get("t_prev")
        if _fin(prev) and (now - prev > EVF_JUMP_S or now < prev - EVF_BACK_S):
            f["jumps"] += 1
            f["dropped"] += _evf_jump(self, now, prev)
        if now - f.get("chk", 0) >= EVF_CHECK_S or now < f.get("chk", 0):
            f["chk"] = now
            syn = _evf_sync(self.tq, now)
            f["dropped"] += _evf_drop(self, now, lambda e: _evf_bad(e, now, syn), "Altersgrenze")
    except Exception as ex:
        self.log("evlFix:", ex)
    f["t_prev"] = now
    before = set(self.pend)
    cur = _evf_orig_update(self, st, now)
    try:
        nz = (st or {}).get("noise") or {}
        nt = nz.get("t")
        if nz.get("stale") and _fin(nt):
            for k, e in self.pend.items():
                if k not in before and e.get("end") == now and e.get("grp") in ("qrm", "thunder") and not k.startswith("gps|") and e["start"] <= nt < now:
                    e["end"], e["note"] = int(nt), "Ende = letzte Messung (danach keine QRM-Messung)"
    except Exception as ex:
        self.log("evlFix Ende:", ex)
    return cur


EvLog.__init__ = _evf_init
EvLog.update = _evf_update


def selftest_evlfix():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="evlfix-") as tmp:
        W = {}

        def wj(p, d):
            json.dumps(d, allow_nan=False)
            W[p] = json.loads(json.dumps(d))

        def lj(p, dflt):
            return json.loads(json.dumps(W[p])) if p in W else dflt
        GOOD = "C0A8B20F,192.168.178.15,2,1791830000.1,0.000012,0.000020,0.000030,-1.2,0.001,0.02,0.000400,0.000300,64.0,Normal"
        BAD = "00000000,,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,1.0,1.0,0.0,Not synchronised"
        src = [BAD]
        tq = lambda: TimeQ(lambda: src[0])
        lg = []
        L = lambda *a: lg.append(" ".join(str(x) for x in a))
        t0 = 1787600000                                  # "24.08." (Uhr nach Boot)
        rot = {"noise": {"t": t0, "bands": [{"id": "n2m", "short": "2m", "ok": True, "lvl": "rot", "raise": 12, "learning": False, "cars": [], "trend": {"on": False}}],
                         "thunder": {"lvl": "gruen"}}}
        grn = {"noise": {"bands": [{"id": "n2m", "short": "2m", "ok": True, "lvl": "gruen", "learning": False}], "thunder": {"lvl": "gruen"}}}
        # 1) Uhrsprung im Lauf: Ereignis vor Sync geoeffnet, Uhr springt +68 d -> verworfen, neues Ereignis ab jetzt
        e = EvLog(tmp, lj, wj, L, now=t0, tq=tq())
        e.update(rot, t0)
        e.update(rot, t0 + 30)
        assert e.open["n2m|floor"]["start"] == t0 and not e.open["n2m|floor"]["start_tq"]["sync"]
        src[0] = GOOD
        t1 = t0 + 68 * 86400
        e.update(rot, t1)
        assert e.open["n2m|floor"]["start"] == t1 and e.evf["jumps"] == 1 and e.evf["dropped"] == 1, (e.open, e.evf)
        vw = read_lines(os.path.join(mon_dir(tmp, t1), "sdr_events_verworfen.jsonl"))
        assert len(vw) == 1 and vw[0]["start"] == t0 and "Uhrsprung" in vw[0]["verworfen"] and any("evlFix: 1 Ereignis" in x for x in lg), (vw, lg)
        assert not read_lines(os.path.join(mon_dir(tmp, t0), "sdr_events.jsonl")), "Geist darf nicht ins Ereignis-Archiv"
        e.update(rot, t1 + 30)
        assert e.evf["jumps"] == 1 and e.open["n2m|floor"]["start"] == t1
        # 2) Geist in der Datei (Start ohne Sync, laeuft seit 1630 h, wird staendig aktualisiert) -> beim Start verworfen
        f = os.path.join(tmp, "sdr_events.json")
        ghost = {"key": "n2m|floor", "band": "2m", "kind": "Rauschboden", "grp": "qrm", "lvl": "rot", "start": t1 - 1630 * 3600, "last": t1 - 10,
                 "start_tq": {"sync": False, "na": "chronyc ohne Antwort"}}
        okev = {"key": "n70|floor", "band": "70cm", "kind": "Rauschboden", "grp": "qrm", "lvl": "gelb", "start": t1 - 3 * 86400, "last": t1 - 10, "start_tq": {"sync": True, "s": 2}}
        lastg = {"key": "x", "band": "2m", "kind": "Träger", "grp": "qrm", "lvl": "gelb", "start": t1 - 1700 * 3600, "end": t1 - 3600, "start_tq": {"sync": False}}
        lastok = {"key": "y", "band": "2m", "kind": "Träger", "grp": "qrm", "lvl": "gelb", "start": t1 - 7200, "end": t1 - 3600, "start_tq": {"sync": False}}
        W[f] = {"open": {"n2m|floor": ghost, "n70|floor": okev}, "pend": {}, "last": [lastg, lastok], "n": 2}
        lg[:] = []
        e2 = EvLog(tmp, lj, wj, L, now=t1, tq=tq())
        assert list(e2.open) == ["n70|floor"] and [x["key"] for x in e2.last] == ["y"] and e2.evf["dropped"] == 2 and e2.dirty, (e2.open, e2.last)
        assert any("beim Start" in x for x in lg), lg
        # ohne Uhrsync (Pi offline) wird nichts wegen Alter verworfen
        src[0] = BAD
        e3 = EvLog(tmp, lj, wj, L, now=t1, tq=tq())
        assert "n2m|floor" in e3.open and e3.evf["dropped"] == 0
        # Start in der Zukunft (Uhr zurueck) -> verworfen
        W[f] = {"open": {"n2m|floor": dict(ghost, start=t1 + 7200, last=t1 + 7200)}, "pend": {}, "last": []}
        e4 = EvLog(tmp, lj, wj, L, now=t1, tq=tq())
        assert not e4.open and not e4.pend and e4.evf["dropped"] == 1, (e4.open, e4.pend)
        # Uhr rueckwaerts im Lauf
        e4.update(rot, t1)
        e4.update(rot, t1 - 600)
        assert e4.evf["jumps"] == 1 and e4.open["n2m|floor"]["start"] == t1 - 600, e4.open
        # 3) veraltete QRM-Messung: Ereignis endet bei der letzten Messung, nicht jetzt
        src[0] = GOOD
        W.pop(f, None)
        e5 = EvLog(tmp, lj, wj, L, now=t1, tq=tq())
        r2 = json.loads(json.dumps(rot))
        r2["noise"]["t"] = t1 + 100
        e5.update(r2, t1 + 100)
        e5.update(r2, t1 + 1000)
        gr = {"noise": {"t": t1 + 1000, "stale": True, "bands": [{"id": "n2m", "short": "2m", "ok": True, "lvl": "grau", "lvl_alt": "rot", "stale": True}], "thunder": {"lvl": "grau"}}}
        e5.update(gr, t1 + 1000 + 3000)
        assert e5.pend["n2m|floor"]["end"] == t1 + 1000 and "letzte Messung" in e5.pend["n2m|floor"]["note"], e5.pend
        e5.update(gr, t1 + 1000 + 3000 + GAP_S + 5)
        fin = [x for x in e5.last if x["key"] == "n2m|floor"]
        assert fin and fin[-1]["dur"] == 900 and not e5.open, (fin, e5.open)
        # normaler Ablauf unveraendert (kein Sprung bei Takt < 1 h)
        e6 = EvLog(tmp, lj, wj, L, now=t1, tq=tq())
        for i in range(0, 7200, 600):
            e6.update(rot, t1 + i)
        assert e6.evf["jumps"] == 0 and e6.open["n2m|floor"]["start"] == t1
    return "evlFix ok (Uhrsprung > %d s vor/%d s zurueck verwirft Ereignisse vor dem Sprung, Start ohne Sync > %d h verworfen nur bei synchroner Uhr, Zukunft verworfen, Nebenarchiv sdr_events_verworfen.jsonl, Ende bei veralteter Messung = letzte Messung)" % (
        EVF_JUMP_S, EVF_BACK_S, EVF_GHOST_S // 3600)
# ===== /evlFix =====
MK_C54_BEV_EOF
EXPECT_GRD="2d732728b615aef18e46e27b4a6214ac40bb2648174cb62737fe7c88bf05a53b"
cat > "$W/guard.py" << 'MK_C54_GRD_EOF'
"""Guard commit54 (qrmRun dashboard.py, qrmLage prepper_sdr.py, evlFix prepper_evlog.py): je Datei genau ein Block vor __main__,
prepper_sdr.py und prepper_evlog.py zusaetzlich je eine Selbsttest-Zeile im __main__-Teil.
  guard.py revert NEU_VERZ ALT_VERZ W   -> ALT_VERZ/{dashboard,prepper_sdr,prepper_evlog}.py = NEU ohne commit54 (byte-genau)
  guard.py check  ALT_VERZ NEU_VERZ W   -> Rueckbau = ALT, statische Regeln (kein Mesh/Netz/Prozess/DB/Gain), Verhalten mit Attrappen, Seiten-Skript mit node
  guard.py mutate ALT_VERZ NEU_VERZ W   -> Mutationstest (jede Mutation muss check scheitern lassen)
W enthaelt blk_dsh.py, blk_sdr.py, blk_evl.py, edits.py. GUARD_NO_NODE=1 schaltet den node-Test ab."""
import ast, contextlib, importlib.util, io, json, os, re, shutil, subprocess, sys, tempfile, time

ANCH = '\n\nif __name__ == "__main__":\n'
FILES = {"dsh": ("dashboard.py", "qrmRun"), "sdr": ("prepper_sdr.py", "qrmLage"), "evl": ("prepper_evlog.py", "evlFix")}
BAD_ID = re.compile(r"mesh|telegram|wd_emit|sqlite|gain|subprocess|socket|urllib|requests|popen|^system$|^eval$|^exec$|__import__|thread|^route$|add_url_rule|hb_|_hb$|alarm|send", re.I)
IMPORTS = {"dsh": set(), "sdr": {"tempfile", "shutil"}, "evl": {"tempfile"}}
CONSTS = {"sdr": {"QRL_PAUSE_MAX_S": 21600, "QRL_STALE_S": 3600, "QRL_HEAL_EVERY_S": 60},
          "evl": {"EVF_GHOST_S": 86400, "EVF_JUMP_S": 3600, "EVF_BACK_S": 60, "EVF_FUT_S": 600, "EVF_CHECK_S": 60}, "dsh": {}}
WRITERS = {"sdr": {"set_lage", "qrl_heal", "selftest_qrmlage"}, "evl": {"selftest_evlfix"}, "dsh": set()}
PATCHED = {"sdr": {("Planner", "lage_apply"), ("Planner", "noise_summary")}, "evl": {("EvLog", "__init__"), ("EvLog", "update")}, "dsh": set()}
JS_BAD = ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "localStorage", "sessionStorage", "eval(", "Function(", "XMLHttpRequest", "/api/mesh", "method:",
          "http://", "https://", "sendBeacon", "location.reload", "setInterval", "setTimeout", "fetch("]
JS_NEED = ["if(N.run&&typeof N.run.stale==='boolean')return N.run.stale;", "U={skip:(N.run||{}).why||(D.uf||{}).skip}", "(o?'QRM steht – ':'')+'Messung alle '+Math.round((R.iv||D.iv||900)/60)+' min'",
           "+(o&&R.why?' · Grund: '+R.why:'')+(R.next?(o?' · nächster Versuch ':' · nächste ')+hm(R.next):(o?' · kein Termin geplant':''))",
           "grau:(N.t&&ufStale()?'grau – veraltet (letzte Messung vor '+ufAge(N.t)+')':'noch keine Messung')}[q]||q)", "(o?' (vor '+ufAge(N.t)+')':'')"]
FIX_UF = '<script id="sdrn-js">\n(function(){var D;try{D=JSON.parse(document.getElementById(\'sdrnData\').textContent);}catch(e){return;}\nvar COL={gruen:\'#22c55e\',gelb:\'#eab308\',rot:\'#ef4444\',grau:\'#64748b\',trend:\'#f97316\'};var TXT={gruen:\'ruhig\',gelb:\'erhöht\',rot:\'stark\',grau:\'keine Messung\'};\nfunction el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined&&x!==null)e.textContent=x;return e;}\nfunction d2(x){return x<10?\'0\'+x:\'\'+x;}function hm(t){var d=new Date(t*1000);return d2(d.getHours())+\':\'+d2(d.getMinutes());}\nfunction dm(t){var d=new Date(t*1000);return d2(d.getDate())+\'.\'+d2(d.getMonth()+1)+\'. \'+hm(t);}\nfunction nf(v,k){return (v===null||v===undefined)?\'–\':(k&&v>0?\'+\':\'\')+String(Math.round(v*10)/10).replace(\'.\',\',\');}\nfunction mhz(v){return String(v).replace(\'.\',\',\');}\nvar SVG=\'http://www.w3.org/2000/svg\';/* umweltFlach */function ufNow(){return (typeof D.now===\'number\')?D.now:Math.floor(Date.now()/1000);}\nfunction ufAge(t){var s=Math.max(0,ufNow()-t);return s>=86400?Math.floor(s/86400)+\' d\':(s>=3600?Math.floor(s/3600)+\' h\':Math.max(1,Math.floor(s/60))+\' min\');}\nfunction ufStale(){var N=D.noise||{};return !N.t||(ufNow()-N.t)>UF_F*(D.iv||900);}\nfunction ufNo(k){if(k!==\'snr\'&&ufStale()){var N=D.noise||{},U=D.uf||{};return \'keine Kurve – \'+(N.t?\'letzte Messung vor \'+ufAge(N.t):\'noch keine Messung\')+\' (Messung läuft nicht\'+(U.skip?\': \'+U.skip:\'\')+\')\';}return \'noch zu wenig Messwerte für eine Kurve\';}\nfunction ufLast(N){var o=ufStale();var x=el(\'div\',\'small\'+(o?\' uf-old\':\'\'),\'Messung alle \'+Math.round((D.iv||900)/60)+\' min\'+(N.t?\' · zuletzt \'+dm(N.t)+(o?\' (vor \'+ufAge(N.t)+\' – läuft nicht)\':\'\'):\' · noch keine Messung\'));return x;}\nfunction ufInfo(L){var d=el(\'details\',\'uf-i\');d.appendChild(el(\'summary\',\'\',\'ⓘ Erklärung\'));L.forEach(function(t){d.appendChild(el(\'div\',\'small\',t));});return d;}\nvar UF_F=3;\nfunction chart(box,pts,key,col,base){box.textContent=\'\';var W=320,H=90;var s=document.createElementNS(SVG,\'svg\');s.setAttribute(\'viewBox\',\'0 0 \'+W+\' \'+H);s.style.width=\'100%\';s.style.height=\'90px\';\nvar v=pts.filter(function(p){return typeof p[key]===\'number\';});if(v.length<2){box.appendChild(el(\'div\',\'small\',ufNo(key)));return;}\nvar x0=v[0].ts,x1=v[v.length-1].ts,ys=v.map(function(p){return p[key];});if(typeof base===\'number\')ys.push(base);var lo=Math.min.apply(null,ys),hi=Math.max.apply(null,ys);if(hi-lo<1){hi+=0.5;lo-=0.5;}\nfunction X(t){return 4+(W-8)*(t-x0)/Math.max(1,x1-x0);}function Y(y){return H-12-(H-22)*(y-lo)/(hi-lo);}\nif(typeof base===\'number\'){var b=document.createElementNS(SVG,\'line\');b.setAttribute(\'x1\',4);b.setAttribute(\'x2\',W-4);b.setAttribute(\'y1\',Y(base));b.setAttribute(\'y2\',Y(base));b.setAttribute(\'stroke\',\'#64748b\');b.setAttribute(\'stroke-dasharray\',\'4 3\');s.appendChild(b);}\nvar d=\'\';v.forEach(function(p,i){d+=(i?\'L\':\'M\')+X(p.ts).toFixed(1)+\' \'+Y(p[key]).toFixed(1);});var pa=document.createElementNS(SVG,\'path\');pa.setAttribute(\'d\',d);pa.setAttribute(\'fill\',\'none\');pa.setAttribute(\'stroke\',col);pa.setAttribute(\'stroke-width\',\'2\');s.appendChild(pa);\n[[lo,H-2],[hi,10]].forEach(function(q){var t=document.createElementNS(SVG,\'text\');t.setAttribute(\'x\',W-4);t.setAttribute(\'y\',q[1]);t.setAttribute(\'fill\',\'#64748b\');t.setAttribute(\'font-size\',\'9\');t.setAttribute(\'text-anchor\',\'end\');t.textContent=nf(q[0]);s.appendChild(t);});\nvar t0=document.createElementNS(SVG,\'text\');t0.setAttribute(\'x\',4);t0.setAttribute(\'y\',H-2);t0.setAttribute(\'fill\',\'#64748b\');t0.setAttribute(\'font-size\',\'9\');t0.textContent=dm(x0);s.appendChild(t0);box.appendChild(s);}\nfunction toggle(card,cb){var w=el(\'div\');w.style.margin=\'4px 0\';var on=\'d\';[[\'d\',\'24 h\'],[\'w\',\'14 Tage\']].forEach(function(o){var b=el(\'button\',\'sdrn-btn\'+(o[0]===on?\' on\':\'\'),o[1]);b.type=\'button\';b.onclick=function(){on=o[0];[].forEach.call(w.children,function(x){x.className=\'sdrn-btn\';});b.className=\'sdrn-btn on\';cb(on);};w.appendChild(b);});card.appendChild(w);return function(){return on;};}\nfunction render(){var N=D.noise||{},H=D.hist||{},B=N.bands||[];var host=document.getElementById(\'sdrnHost\');if(!host)return;host.textContent=\'\';\n/* Stoersender / QRM */\nvar c=el(\'div\',\'sdrn-card card\');c.id=\'sdrnQrm\';c.appendChild(el(\'div\',\'title\',\'📡 Störsender / QRM\'));var q=(N.qrm||{}).lvl||\'grau\';var G0=D.gps||{};var RK={grau:0,gruen:1,gelb:2,rot:3};if(G0.lvl&&RK[G0.lvl]>RK[q])q=G0.lvl;\nvar TB=B.filter(function(b){return b.ok&&b.trend&&b.trend.on&&b.lvl===\'gruen\';});var big=el(\'div\',\'sdrn-big\',\'● \'+({gruen:\'grün – ruhig\',gelb:\'gelb – erhöht\',rot:\'rot – stark gestört\',grau:\'noch keine Messung\'}[q]||q)+(q===\'gruen\'&&TB.length?\' · ↗ Trend steigend: \'+TB.map(function(b){return b.short;}).join(\', \'):\'\'));big.style.color=(q===\'gruen\'&&TB.length)?COL.trend:(COL[q]||COL.grau);c.appendChild(big);\nc.appendChild(ufLast(N));\nvar sel=(G0.lvl===\'rot\'||G0.lvl===\'gelb\')?\'dachgps\':((B.filter(function(b){return b.lvl===\'rot\'||b.lvl===\'gelb\';})[0]||{}).id||(G0.src&&G0.ok?\'dachgps\':(B[0]||{}).id));var box=el(\'div\');\nvar rows=el(\'div\');rows.style.margin=\'6px 0\';\nfunction drawQ(){if(sel===\'dachgps\'||sel===\'dachglo\'){var k0=sel===\'dachgps\'?\'G\':\'R\',S0=((G0.sys||{})[k0])||{};chart(box,(((D.ghist_s||{})[k0]||{})[gq()])||[],\'snr\',k0===\'G\'?\'#93c5fd\':\'#c4b5fd\',S0.b_snr);return;}if(sel===\'dachgps\'){chart(box,((D.ghist||{})[gq()])||[],\'snr\',COL[G0.lvl]||\'#93c5fd\',G0.b_snr);return;}var hh=(H[sel]||{})[gq()]||[];var bb=B.filter(function(b){return b.id===sel;})[0]||{};chart(box,hh,\'floor\',COL[bb.lvl]||\'#93c5fd\',bb.base);}\nvar UFG=[];B.forEach(function(b){if(b.id===\'gps\'&&b.lvl!==\'gelb\'&&b.lvl!==\'rot\')return;if(!b.ok){UFG.push(b);return;}var r=el(\'div\',\'sdrn-row\'+(b.id===sel?\' sel\':\'\'));var dot=el(\'span\',\'dot\');dot.style.background=COL[b.lvl]||COL.grau;r.appendChild(dot);r.appendChild(el(\'span\',\'nm\',b.short));\nvar tr=b.trend||{};var isT=!!(b.ok&&tr.on&&b.lvl===\'gruen\');if(isT){dot.style.background=COL.trend;dot.className=\'dot tr\';}\nvar t;if(!b.ok){t=b.why||\'nicht messbar\';}else{t=nf(b.floor)+\' dB\'+(typeof b.raise===\'number\'?\' · \'+nf(b.raise,1)+\' dB\':\' · Grundlinie lernt\');if(b.lvl===\'gelb\'||b.lvl===\'rot\')t+=\' · Schwelle +\'+nf(b.yel)+\'/+\'+nf(b.red)+\' dB (\'+(b.src||\'\')+\')\';if(isT)t+=\' · ↗ Trend steigend \'+nf(tr.e,1)+\' dB\'+(tr.since?\' seit \'+dm(tr.since):\'\');if(b.learning)t+=\' · lernt\';else if(b.n_pers)t+=\' · \'+b.n_pers+\' neue Träger\';}\nif(b.id===\'gps\')t=\'Stick-L1 (Nebenwert) · \'+t;r.appendChild(el(\'span\',\'tx\',t));r.title=b.label;\nr.onclick=function(){sel=b.id;[].forEach.call(rows.children,function(x){x.classList.remove(\'sel\');});r.classList.add(\'sel\');drawQ();};rows.appendChild(r);(b.ok&&!b.learning?(b.cars||[]):[]).forEach(function(x){var cr=el(\'div\',\'sdrn-row sdrn-car\');cr.appendChild(el(\'span\',\'dot\'));cr.appendChild(el(\'span\',\'nm\',\'\'));cr.appendChild(el(\'span\',\'tx\',\'↳ \'+mhz(x.f)+\' MHz +\'+nf(x.db)+\' dB seit \'+dm(x.since)));rows.appendChild(cr);});});\nvar G=D.gps||{};if(G.src){var SY=G.sys||{};function fx(m){return m>=3?\'3D\':(m===2?\'2D\':\'kein Fix\');}\nfunction grow(id,nm,col,blink,txt,tip){var x=el(\'div\',\'sdrn-row\'+(sel===id?\' sel\':\'\'));var dd=el(\'span\',\'dot\'+(blink?\' blink\':\'\'));dd.style.background=col;x.appendChild(dd);x.appendChild(el(\'span\',\'nm\',nm));x.appendChild(el(\'span\',\'tx\',txt));x.title=tip;\nx.onclick=function(){sel=id;[].forEach.call(rows.children,function(y){y.classList.remove(\'sel\');});x.classList.add(\'sel\');drawQ();};return x;}\nvar bad=(G.lvl===\'gelb\'||G.lvl===\'rot\');\nfunction srow(k,nm){var P=SY[k]||null,E=G[k]||null,head=(k===\'G\'?\'GPS\':\'GLONASS\');\nif(G.ok===false){return [COL.grau,false,(k===\'G\'?\'Dach-GPS nicht erreichbar\'+(G.since?\' seit \'+dm(G.since):\'\')+(typeof G.snr===\'number\'?\' · zuletzt \'+nf(G.snr)+\' dB-Hz, \'+G.used+\'/\'+G.seen+\' Sat (\'+dm(G.last_t)+\')\':\'\'):head+\': –\')];}\nif(!G.ok){return [COL.grau,false,head+\': \'+(G.why||\'noch keine Abfrage\')];}\nif(!P||P.state===\'keine Daten\'||(!P.now_n&&P.state!==\'bewertet\')){return [COL.grau,false,head+\': keine Satelliten/Daten\'+(P&&P.samples?\' (jetzt keine, \'+P.samples+\' Proben gespeichert)\':\'\')];}\nvar cur=head+\' \'+nf(P.now_ss)+\' dB-Hz · \'+P.now_n+\' Sat\'+(k===\'G\'?\' · \'+fx(G.mode)+(typeof G.hdop===\'number\'?\' · HDOP \'+nf(G.hdop):\'\'):\'\');\nif(P.state===\'lernt\'){return [COL.grau,true,cur+\' · lernt · \'+P.ref+\' Proben / ~\'+nf(P.eta_h)+\' h\'];}\nvar t=cur+(E&&typeof E.drop===\'number\'?\' · \'+nf(-E.drop,1)+\' dB\':\'\');\nvar hit=(k===\'G\')?bad&&G.cls!==\'GLONASS\':bad&&(G.cls===\'breitbandig\'||G.cls===\'GLONASS\');\nif(hit&&E&&typeof E.yel===\'number\')t+=\' · Schwelle -\'+nf(E.yel)+\'/-\'+nf(E.red)+\' dB\';\nif(k===\'G\'&&G.why&&G.why!==\'normal\')t+=\' · \'+G.why;if(k===\'R\'&&hit&&G.cls)t+=\' · \'+G.cls;\nreturn [hit?(COL[G.lvl]||COL.grau):COL.gruen,false,t];}\nvar tip=\'gpsd \'+(G.host||\'\')+\' (Dachantenne): Signalstärke je System und Höhenband (10–30°, 30–60°, >60°) gegen 7-Tage-Grundlinie; Dach gesamt \'+nf(G.snr)+\' dB-Hz, \'+(G.used||0)+\'/\'+(G.seen||0)+\' Sat. Grau blinkend = lernt noch (Bewertung ab 36 Proben über 12 h). Beide Systeme schwächer = breitbandig, nur GPS = L1-schmalbandig.\';\nvar a1=srow(\'G\'),a2=srow(\'R\');\nrows.insertBefore(grow(\'dachglo\',\'GLO\',a2[0],a2[1],a2[2],tip),rows.firstChild);rows.insertBefore(grow(\'dachgps\',\'GPS\',a1[0],a1[1],a1[2],tip),rows.firstChild);}\nif(UFG.length)rows.appendChild(el(\'div\',\'sdrn-row uf-grey\',\'○ nicht gemessen: \'+UFG.map(function(b){return b.short;}).join(\', \')+\' · \'+(UFG[0].why||\'nicht messbar\')));if(!B.length&&!(D.gps||{}).src)rows.appendChild(el(\'div\',\'small\',\'noch keine Messung (erste Messung kurz nach dem Start der Automatik)\'));c.appendChild(rows);var gq=toggle(c,drawQ);c.appendChild(box);drawQ();\nc.appendChild(ufInfo(["Rauschboden je Band gegen Grundlinie (Median 7 Tage, MW/KW je Tagesstunde; Schwelle max(5 dB, 4×MAD) gelb, max(10 dB, 6×MAD) rot), langsamer Anstieg als ↗ Trend, neue Dauerträger. Nur Leistungsmessung, kein Inhalt.","Kurve: Rauschboden (dB, relativ) des gewählten Bandes. Hinweis, keine Peilung oder Garantie: eigene Geräte (Netzteile, Pi, LED) stören oft selbst."]));host.appendChild(c);\n/* Gewitter */\nvar th=N.thunder||{};var g=el(\'div\',\'sdrn-card card\');g.id=\'sdrnThunder\';var tl=th.lvl||\'grau\';var UFR=(tl!==\'gelb\'&&tl!==\'rot\');var gH=g,gs=null;if(UFR){var gd=el(\'details\',\'uf-more\');gd.id=\'sdrnThunderX\';gs=el(\'summary\',\'uf-sum\');gs.appendChild(el(\'span\',\'uf-st\',\'⚡ Gewitter \'));gd.appendChild(gs);g.appendChild(gd);g=gd;}else{g.appendChild(el(\'div\',\'title\',\'⚡ Gewitter-Hinweis\'));}\nvar b2=el(\'div\',\'sdrn-big\',\'● \'+({gruen:\'grün – ruhig\',gelb:\'gelb – mehr Impulse als üblich\',rot:\'rot – stark impulsiv, steigend\',grau:\'nicht messbar\'}[tl]||tl));b2.style.color=COL[tl]||COL.grau;if(UFR){b2.className=\'uf-st2\';if(typeof th.bb_pm===\'number\')b2.textContent+=\' · \'+nf(th.bb_pm)+\'/min\';gs.appendChild(b2);}else{g.appendChild(b2);g.appendChild(el(\'div\',\'small\',"Grober Hinweis – keine Blitzortung, keine Unwetterwarnung."));}\ng.appendChild(el(\'div\',\'small\',(typeof th.bb_pm===\'number\'?\'Breitbandige Impulse \'+nf(th.bb_pm)+\'/min\'+(typeof th.base===\'number\'?\' (üblich \'+nf(th.base)+\'/min, \'+(th.src||\'\')+\')\':\'\')+((tl===\'gelb\'||tl===\'rot\')&&typeof th.yel===\'number\'?\' · Schwelle \'+nf(th.yel)+\'/\'+nf(th.red)+\' pro min\':\'\')+\' auf \'+(th.band===\'hf10\'?\'KW 10 MHz\':\'MW\')+\' · \':\'\')+(th.why||\'\')+\'.\'));\nvar box2=el(\'div\');function drawT(){chart(box2,(H.impulse||{})[gt()]||[],\'bb_pm\',COL[tl]||\'#93c5fd\',null);}var gt=toggle(g,drawT);g.appendChild(box2);drawT();\ng.appendChild(ufInfo(["Nur ein Hinweis: Blitze erzeugen kurze breitbandige Knackse (Sferics) auf Mittel-/Kurzwelle, aber auch Weidezäune, Zündanlagen und Schaltnetzteile. Braucht Direktabtastung (NESDR SMArt v5) und eine Draht-/KW-Antenne; keine Entfernungs- oder Blitzortung, keine Unwetterwarnung."]));host.appendChild(gH);}\nrender();var ufT=Date.now();function ufPoll(){if(document.hidden)return;ufT=Date.now();fetch(\'/api/sdr/noise?evl=1\',{credentials:\'same-origin\',cache:\'no-store\'}).then(function(r){return r.json();}).then(function(x){var ev=x.evl||null;delete x.evl;D=x;render();if(window.ufEvl)window.ufEvl(ev);}).catch(function(){});}\nsetInterval(ufPoll,120000);document.addEventListener(\'visibilitychange\',function(){if(!document.hidden&&Date.now()-ufT>=120000)ufPoll();});})();\n</script>'
NODE_JS = "\nvar R={log:[],fetch:[],iv:[]};var NOW=1793500000;\nfunction E(t){this.tagName=String(t).toUpperCase();this.children=[];this.parentElement=null;this.className='';this._t='';this.style={};this.dataset={};this.id='';this.attrs={};var me=this;\nthis.classList={add:function(c){if(!me.classList.contains(c))me.className=(me.className?me.className+' ':'')+c;},remove:function(c){me.className=me.className.split(' ').filter(function(x){return x&&x!==c;}).join(' ');},contains:function(c){return me.className.split(' ').indexOf(c)>=0;}};}\nE.prototype.appendChild=function(c){if(c.parentElement)c.parentElement.removeChild(c);c.parentElement=this;this.children.push(c);return c;};\nE.prototype.insertBefore=function(c,r){if(c.parentElement)c.parentElement.removeChild(c);c.parentElement=this;var i=this.children.indexOf(r);if(i<0)this.children.push(c);else this.children.splice(i,0,c);return c;};\nE.prototype.removeChild=function(c){var i=this.children.indexOf(c);if(i>=0)this.children.splice(i,1);c.parentElement=null;return c;};\nE.prototype.setAttribute=function(k,v){this.attrs[k]=v;};\nObject.defineProperty(E.prototype,'firstChild',{get:function(){return this.children[0]||null;}});\nObject.defineProperty(E.prototype,'lastElementChild',{get:function(){return this.children[this.children.length-1]||null;}});\nObject.defineProperty(E.prototype,'childNodes',{get:function(){return this.children;}});\nObject.defineProperty(E.prototype,'textContent',{get:function(){return this._t+this.children.map(function(c){return c.textContent;}).join('');},set:function(v){this._t=String(v);this.children=[];}});\nfunction find(n,id){if(n.id===id)return n;for(var i=0;i<n.children.length;i++){var x=find(n.children[i],id);if(x)return x;}return null;}\nfunction all(n,f,o){o=o||[];if(f(n))o.push(n);n.children.forEach(function(c){all(c,f,o);});return o;}\nvar body=new E('body');var VL={};\nglobal.document={hidden:false,createElement:function(t){return new E(t);},createElementNS:function(ns,t){return new E(t);},createTextNode:function(s){var e=new E('#text');e._t=String(s);return e;},\ngetElementById:function(id){return find(body,id);},addEventListener:function(k,f){VL[k]=f;},querySelectorAll:function(){return [];}};\nglobal.window=global;global.location={pathname:'/umwelt'};global.alert=function(){};\nvar T=0;var realNow=Date.now;Date.now=function(){return NOW*1000+T;};\nglobal.setInterval=function(f,ms){R.iv.push(ms);R.ivf=R.ivf||{};R.ivf[ms]=f;return 1;};\nvar PAY=null;global.fetch=function(u,o){R.fetch.push(u);return Promise.resolve({json:function(){return Promise.resolve(JSON.parse(JSON.stringify(PAY)));}});};\nfunction el(t,id,txt){var e=new E(t);e.id=id;if(txt!==undefined)e._t=txt;body.appendChild(e);return e;}\nmodule.exports={E:E,body:body,R:R,el:el,find:find,all:all,VL:VL,setT:function(x){T=x;},setPay:function(p){PAY=p;},now:NOW};\n"


def rd(p):
    return open(p, encoding="utf-8").read()


def blk(W, k):
    return rd(os.path.join(W, "blk_%s.py" % k)).rstrip("\n") + "\n"


def edits(W):
    g = {}
    exec(compile(rd(os.path.join(W, "edits.py")), "edits", "exec"), g)
    return g


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def revert(txt, B, E):
    blkx = "\n\n" + B.rstrip("\n")
    assert txt.count(blkx + ANCH) == 1, "Block nicht genau einmal direkt vor __main__"
    t = txt.replace(blkx + ANCH, ANCH, 1)
    assert B.splitlines()[0] not in t, "Block-Marker ausserhalb des Blocks"
    for o, n in E:
        assert t.count(n) == 1, "Stelle nicht genau einmal: %r" % n[:60]
        t = t.replace(n, o, 1)
    return t


def revert_all(neud, W):
    E = edits(W)
    out = {}
    for k, (fn, _) in FILES.items():
        out[fn] = revert(rd(os.path.join(neud, fn)), blk(W, k), E["%s_EDITS" % k.upper()])
    return out


def static(k, B):
    fn, name = FILES[k]
    if not B.startswith("# ===== %s:" % name) or not B.rstrip("\n").endswith("# ===== /%s =====" % name):
        fail("%s: Block beginnt/endet nicht mit Marker" % fn)
    try:
        T = ast.parse(B)
    except SyntaxError as e:
        fail("%s: Syntax %s" % (fn, e))
    seen = {}
    for node in T.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            t = node.targets[0]
            if isinstance(t, ast.Name) and t.id in CONSTS[k]:
                try:
                    seen[t.id] = ast.literal_eval(node.value) if not isinstance(node.value, ast.BinOp) else eval(compile(ast.Expression(node.value), "c", "eval"), {})
                except Exception:
                    seen[t.id] = None
            if isinstance(t, ast.Attribute):
                if not (isinstance(t.value, ast.Name) and (t.value.id, t.attr) in PATCHED[k]):
                    fail("%s: unerwartete Ersetzung %s" % (fn, ast.dump(t)[:80]))
    if seen != CONSTS[k]:
        fail("%s: Konstanten %s statt %s" % (fn, seen, CONSTS[k]))
    pt = {(n.targets[0].value.id, n.targets[0].attr) for n in T.body if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Attribute)}
    if pt != PATCHED[k]:
        fail("%s: ersetzte Methoden %s statt %s" % (fn, sorted(pt), sorted(PATCHED[k])))
    funcs = {}
    for node in ast.walk(T):
        if isinstance(node, ast.FunctionDef):
            for sub in ast.walk(node):
                funcs.setdefault(id(sub), node.name)
    for node in ast.walk(T):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for a in node.names:
                if a.name.split(".")[0] not in IMPORTS[k]:
                    fail("%s: Import %s" % (fn, a.name))
            if funcs.get(id(node), "").startswith("selftest") is False:
                fail("%s: Import ausserhalb Selbsttest" % fn)
        nm = node.id if isinstance(node, ast.Name) else node.attr if isinstance(node, ast.Attribute) else node.name if isinstance(node, ast.FunctionDef) else None
        if nm and BAD_ID.search(nm):
            fail("%s: verbotener Name %s" % (fn, nm))
        if isinstance(node, ast.Call):
            f = node.func
            cn = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""
            fu = funcs.get(id(node), "")
            if cn in ("write_json", "write_private", "rewrite_lines", "remove", "unlink", "rename", "replace_file", "chmod") and fu not in WRITERS[k]:
                fail("%s: schreibt Datei ausserhalb erlaubter Stellen (%s in %s)" % (fn, cn, fu or "Modulebene"))
            if cn == "open" and not fu.startswith("selftest"):
                fail("%s: open ausserhalb Selbsttest" % fn)
            if cn == "write_json" and not fu.startswith("selftest") and "sdr_lage.json" not in (ast.unparse(node.args[0]) if node.args else ""):
                fail("%s: write_json nur auf sdr_lage.json" % fn)
            if cn == "append_line":
                a0 = ast.unparse(node.args[0]) if node.args else ""
                if "sdr_events_verworfen.jsonl" not in a0:
                    fail("%s: append_line nur ins Nebenarchiv sdr_events_verworfen.jsonl (%s)" % (fn, a0[:60]))
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Attribute) and t.value.attr == "cfg" and not funcs.get(id(node), "").startswith("selftest"):
                    fail("%s: aendert Einstellungen (cfg)" % fn)
        if isinstance(node, ast.Global) and k != "dsh":
            fail("%s: global" % fn)
        if isinstance(node, ast.Global) and k == "dsh" and node.names != ["_SDRN_JS"]:
            fail("%s: global %s" % (fn, node.names))
    if k == "dsh":
        g = {}
        exec(compile(B.split("\n\ndef _qr_apply")[0], "c", "exec"), g)
        for o, n in g["_QR_SDRN_EDITS"]:
            for b in JS_BAD:
                if b in n and b not in o:
                    fail("dashboard.py: Seiten-Skript neu mit %s" % b)
        if re.search(r"\bapp\b|_sdrn_data|view_functions|after_request", B):
            fail("dashboard.py: Block fasst Flask-App/Daten an (nur Anzeige-Skript erlaubt)")
    return "%s: Marker, Konstanten %s, nur %s ersetzt, keine Imports ausser Selbsttest, kein Mesh/Netz/Prozess/DB/Gain/HB, keine Einstellung" % (
        fn, ",".join("%s=%s" % x for x in sorted(CONSTS[k].items())) or "-", ",".join("%s.%s" % x for x in sorted(PATCHED[k])) or "Seiten-Skript")


def load(path, name, d):
    sys.path.insert(0, d)
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        m = importlib.util.module_from_spec(spec)
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(m)
        return m
    finally:
        sys.path.remove(d)


def lj(path):
    return json.load(open(path, encoding="utf-8"))


def beh_sdr(m, ma):
    d = tempfile.mkdtemp(prefix="g54s")
    try:
        f = os.path.join(d, "sdr_lage.json")
        now = time.time()
        sw = dict(m.LAGE_PROFILES["warn"], noise="aus", aprs="an")
        pi = {"profile": "warn", "sw": sw, "at": int(now - 13 * 86400)}
        json.dump(pi, open(f, "w"))
        assert ma.get_lage(d)["sw"]["noise"] == "aus", "Szenario (alt) nicht AUS"
        g = m.get_lage(d)
        assert g["sw"]["noise"] == "an" and g["profile"] == "warn" and dict(g["sw"], noise="aus") == sw and g["qrm_pause"]["expired"], ("Pi-Szenario", g)
        L = []
        assert m.qrl_heal(d, now, lambda *a: L.append(" ".join(map(str, a)))) is True and len(L) == 1 and "qrmLage" in L[0], ("Heal", L)
        h = lj(f)
        assert h["profile"] == "warn" and h["sw"] == dict(sw, noise="an") and h["at"] == pi["at"] and set(h) - set(pi) <= {"noise_heal_at", "noise_heal_was"}, ("Datei nach Heal", h)
        b0 = open(f, "rb").read()
        assert m.qrl_heal(d, now + 10) is False and open(f, "rb").read() == b0, "Heal nicht idempotent"
        assert m.get_lage(d)["sw"]["noise"] == "an" and "qrm_pause" not in m.get_lage(d), "nach Heal"
        # frische Pause (neues Format) und altes Format ohne noise_off_at
        r = m.set_lage(d, src="noise", state="aus")
        t1 = lj(f)["noise_off_at"]
        assert r["sw"]["noise"] == "aus" and abs(t1 - time.time()) < 5, ("Pause setzen", r)
        assert m.get_lage(d, now=t1 + 6 * 3600 - 30)["sw"]["noise"] == "aus" and m.get_lage(d, now=t1 + 6 * 3600 + 30)["sw"]["noise"] == "an", "6-h-Grenze"
        assert m.qrl_heal(d, t1 + 6 * 3600 - 30) is False, "Heal vor Ablauf"
        x = lj(f)
        x["noise_off_at"] = t1 - 1000
        json.dump(x, open(f, "w"))
        m.set_lage(d, src="433", state="an")
        assert lj(f)["noise_off_at"] == t1 - 1000, "anderer Schalter verlaengert Pause"
        json.dump({"profile": "funk", "sw": dict(m.LAGE_PROFILES["funk"], noise="aus"), "at": int(now - 3600)}, open(f, "w"))
        assert m.get_lage(d)["sw"]["noise"] == "aus" and m.get_lage(d, now=now + 5.5 * 3600)["sw"]["noise"] == "auto", "altes Format: Pause ab at"
        # Ruhe unberuehrt
        json.dump({"profile": "ruhe", "sw": dict(m.LAGE_PROFILES["ruhe"]), "at": int(now - 40 * 86400)}, open(f, "w"))
        b0 = open(f, "rb").read()
        assert m.get_lage(d)["sw"]["noise"] == "aus" and m.qrl_heal(d, now) is False and open(f, "rb").read() == b0, "Ruhe veraendert"
        # gleiches Verhalten ohne Pause
        for x in ({"profile": "normal", "sw": dict(m.LAGE_PROFILES["normal"], aprs="aus"), "at": 5}, {"profile": "warn", "sw": dict(m.LAGE_PROFILES["warn"]), "at": 5},
                  {"profile": "funk", "sw": dict(m.LAGE_PROFILES["funk"], noise="an"), "at": 5}, {}, {"profile": "x"}):
            json.dump(x, open(f, "w"))
            assert m.get_lage(d) == ma.get_lage(d), ("ohne Pause anders", x)
        for pr in ("normal", "warn", "funk", "ruhe"):
            a = m.set_lage(d, profile=pr)
            fa = lj(f)
            b = ma.set_lage(d, profile=pr)
            fb = lj(f)
            assert a == b and set(fa) == set(fb) and fa["sw"] == fb["sw"], ("Profil", pr)
        # lage_apply: nur Hauptplaner heilt (hoechstens 1x/min), Original immer
        calls = []
        o = m._qrl_orig_lage_apply
        m._qrl_orig_lage_apply = lambda s: calls.append(s)
        try:
            class P:
                pass
            mp, wp = P(), P()
            mp.main, mp.base, mp.log = None, d, lambda *a: calls.append("log")
            wp.main, wp.base, wp.log = mp, d, lambda *a: None
            json.dump({"profile": "warn", "sw": sw, "at": int(now - 13 * 86400)}, open(f, "w"))
            wp_h = m.Planner.lage_apply
            assert wp_h is m._qrl_lage_apply, "Planner.lage_apply nicht umgehaengt"
            wp_h(wp)
            assert lj(f)["sw"]["noise"] == "aus" and calls == [wp], "Nebenplaner darf nicht heilen"
            wp_h(mp)
            assert lj(f)["sw"]["noise"] == "an" and calls[1:] == ["log", mp], ("Hauptplaner heilt", calls)
            json.dump({"profile": "warn", "sw": sw, "at": int(now - 13 * 86400)}, open(f, "w"))
            wp_h(mp)
            assert lj(f)["sw"]["noise"] == "aus", "Heal oefter als 1x/min"
        finally:
            m._qrl_orig_lage_apply = o
        # noise_summary: Lauf-Zustand, grau, Waechter nur Journal
        boom = []
        saved = {}
        for nm in dir(m):
            if re.search(r"mesh|_wd_emit|hb_problem|alarm_send|send_", nm, re.I) and callable(getattr(m, nm)):
                saved[nm] = getattr(m, nm)
                setattr(m, nm, lambda *a, **k: boom.append(nm))
        on = m._qrl_orig_nsum
        try:
            class Pl:
                def __init__(s, no, q, last, kind="rtl"):
                    s.stickno, s._q, s.last_noise, s.special, s.main = no, q, last, None, None
                    s.cfg = {"noise_interval_s": 600, "dev_kind": kind, "noise_enable": bool(q)}
                    s.ndiag = {"skip": "Meteor-Ueberflug X bald - Messung 5 min spaeter", "skip_t": int(now - 60)}
                    s.lage = {"name": "Warnlage", "sw": {"noise": "an" if q else "aus"}}

                def noise_queue(s):
                    return s._q

                def noise_why_off(s):
                    return m.Planner.noise_why_off(s)

            class N:
                pass
            lg = []
            mn = Pl(1, [], 0, "airspy")
            mn.base, mn.worker, mn.snoise, mn.log = d, None, N(), lambda *a: lg.append(" ".join(map(str, a)))
            h3 = Pl(3, [("nz:0", 60)], now - 100)
            h3.main = mn
            mn.__dict__["hobbies"] = [Pl(4, [], 0), h3]
            json.dump({"mode": "auto"}, open(os.path.join(d, "sdr_mode.json"), "w"))
            T = [now - 13 * 86400]
            ORIG = lambda s: {"t": T[0], "qrm": {"lvl": "rot", "trend": ["n2m"]}, "thunder": {"lvl": "gelb", "bb_pm": 5}, "next": None,
                              "bands": [{"id": "n2m", "ok": True, "lvl": "rot", "n_pers": 1, "cars": [{"f": 1}], "trend": {"on": True}}, {"id": "hf", "ok": False, "lvl": "grau"}]}
            m._qrl_orig_nsum = ORIG
            mn.snoise.d = {"t": T[0]}
            r = m.Planner.noise_summary(mn)
            ru = r["run"]
            assert ru["stale"] and ru["on"] and ru["next"] == int(now - 100 + 600) and r["next"] == ru["next"] and ru["iv"] == 600 and ru["last"] == int(T[0]), ("run", ru)
            assert ru["why"].startswith("Meteor") and ru["age_s"] >= 13 * 86400 - 5 and ru["since"] == int(T[0]) and ru["stale_after_s"] == 3600, ru
            assert r["qrm"]["lvl"] == "grau" and r["qrm"]["lvl_alt"] == "rot" and r["thunder"]["lvl"] == "grau" and r["thunder"]["lvl_alt"] == "gelb", ("grau", r)
            assert [b["lvl"] for b in r["bands"]] == ["grau", "grau"] and r["bands"][0]["lvl_alt"] == "rot" and r["bands"][0]["n_pers"] == 0 and r["bands"][0]["trend"] is None, r["bands"]
            assert r["qrm"]["trend"] == [] and r["stale"] is True and len(lg) == 1 and "QRM steht" in lg[0], (r, lg)
            m.Planner.noise_summary(mn)
            assert len(lg) == 1, "Waechter meldet bei jedem Aufruf"
            for age, st in ((3500, False), (3700, True)):
                T[0] = now - age
                mn.snoise.d = {"t": T[0]}
                r = m.Planner.noise_summary(mn)
                assert r["run"]["stale"] is st and (r["qrm"]["lvl"] == ("grau" if st else "rot")), ("Grenze 1 h", age, r)
            assert len(lg) == 3 and "laeuft wieder" in lg[1], lg
            T[0] = now - 60
            mn.snoise.d = {"t": T[0]}
            r = m.Planner.noise_summary(mn)
            o2 = ORIG(mn)
            assert {k: v for k, v in r.items() if k not in ("run", "next")} == {k: v for k, v in o2.items() if k != "next"}, "frische Werte veraendert"
            # Nebenplaner: run da, next bleibt eigener Wert
            r3 = m.Planner.noise_summary(h3)
            assert r3["next"] is None and r3["run"]["next"] == int(now - 100 + 600), r3
            # niemand misst -> Grund aus Lage; Betriebsart nicht auto -> Grund
            h3._q, h3.cfg["noise_enable"], h3.lage = [], False, {"name": "Warnlage", "sw": {"noise": "aus"}}
            T[0] = now - 7200
            mn.snoise.d = {"t": T[0]}
            r = m.Planner.noise_summary(mn)
            assert r["run"]["why"] == "Messung AUS (Lage Warnlage)" and r["run"]["next"] is None and not r["run"]["on"] and r["next"] is None, r["run"]
            h3._q = [("nz:0", 60)]
            json.dump({"mode": "433"}, open(os.path.join(d, "sdr_mode.json"), "w"))
            assert "Betriebsart 433" in m.Planner.noise_summary(mn)["run"]["why"]
            assert not boom, ("Mesh/HB aufgerufen", boom)
        finally:
            m._qrl_orig_nsum = on
            for k2, v in saved.items():
                setattr(m, k2, v)
        with contextlib.redirect_stdout(io.StringIO()):
            s = m.selftest_qrmlage()
        assert s.startswith("selftest qrmLage ok"), s
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return "Lage: Pi-Fall Warnlage/QRM AUS seit 13 d -> wieder AN, Datei bereinigt (Profil/Schalter/at bleiben), idempotent; Pause 6 h auch altes Format; Ruhe unberuehrt; ohne Pause gleich wie vorher; Heal nur Hauptplaner 1x/min; Lauf-Zustand next/why/stale, grau ab 1 h, Waechter nur bei Wechsel, kein Mesh/HB"


GOOD = "C0A8B20F,192.168.178.15,2,1791830000.1,0.000012,0.000020,0.000030,-1.2,0.001,0.02,0.000400,0.000300,64.0,Normal"
BADQ = "00000000,,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,1.0,1.0,0.0,Not synchronised"


def beh_evl(e, ea):
    def mk():
        W = {}

        def wj(p, dd):
            json.dumps(dd, allow_nan=False)
            W[p] = json.loads(json.dumps(dd))

        def lj2(p, dflt):
            return json.loads(json.dumps(W[p])) if p in W else dflt
        return W, wj, lj2

    def band(lvl, car=False, tr=False):
        return {"id": "n2m", "short": "2m", "ok": True, "lvl": lvl, "raise": 7 if lvl != "gruen" else 1, "learning": False, "n_pers": 1 if car else 0,
                "cars": [{"f": 144800000, "db": 9.0}] if car else [], "trend": {"on": tr, "e": 1.5}}
    seq = []
    t0 = 1792000000
    for i in range(0, 4 * 3600, 30):
        ph = (i // 600) % 6
        lv = ["gruen", "gelb", "rot", "gruen", "gelb", "gruen"][ph]
        seq.append((t0 + i, {"noise": {"t": t0 + i, "bands": [band(lv, car=ph == 2, tr=ph == 4)], "thunder": {"lvl": "gelb" if ph == 1 else "gruen", "bb_pm": 50}},
                             "gps": {"ok": True, "lvl": "rot" if ph == 3 else "gruen", "cls": "GPS"}}))
    res = []
    for mod in (e, ea):
        tmp = tempfile.mkdtemp(prefix="g54e")
        try:
            W, wj, lj2 = mk()
            lg = []
            ev = mod.EvLog(tmp, lj2, wj, lambda *a: lg.append(a), now=t0, tq=mod.TimeQ(lambda: GOOD))
            for j, (t, st) in enumerate(seq):
                if j == len(seq) // 2:
                    ev.save(t)
                    ev = mod.EvLog(tmp, lj2, wj, lambda *a: lg.append(a), now=t + 20, tq=mod.TimeQ(lambda: GOOD))
                ev.update(st, t)
            ev.save(seq[-1][0])
            arch = []
            for root, _, fs in os.walk(tmp):
                for fn in sorted(fs):
                    arch.append((fn, open(os.path.join(root, fn)).read()))
            res.append((W[os.path.join(tmp, "sdr_events.json")], [x for x in arch], len(lg)))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    a, b = res
    norm = lambda x: json.loads(json.dumps(x).replace(json.dumps(tempfile.gettempdir()), ""))
    assert a[0] == b[0] and [x[1] for x in a[1]] == [x[1] for x in b[1]] and a[2] == b[2] == 0, "Normalbetrieb (Uhr synchron, ohne Sprung) anders als vorher"
    assert len(a[0]["last"]) >= 10, "Normalbetrieb ohne Ereignisse (Testfehler)"
    # Pi-Fall: Geist in der Datei
    tmp = tempfile.mkdtemp(prefix="g54e")
    try:
        W, wj, lj2 = mk()
        f = os.path.join(tmp, "sdr_events.json")
        now = 1793460000
        ghost = {"key": "n2m|floor", "band": "2m", "kind": "Rauschboden", "grp": "qrm", "lvl": "rot", "start": now - 1630 * 3600, "last": now - 5, "start_tq": {"sync": False, "na": "chronyc ohne Antwort"}}
        real = {"key": "n70|floor", "band": "70cm", "kind": "Rauschboden", "grp": "qrm", "lvl": "gelb", "start": now - 2 * 86400, "last": now - 5, "start_tq": {"sync": True, "s": 2}}
        W[f] = {"open": {"n2m|floor": ghost, "n70|floor": real}, "pend": {}, "last": [], "n": 0}
        lg = []
        ev = e.EvLog(tmp, lj2, wj, lambda *a: lg.append(" ".join(map(str, a))), now=now, tq=e.TimeQ(lambda: GOOD))
        assert list(ev.open) == ["n70|floor"] and not ev.pend and any("evlFix" in x for x in lg), ("Geist beim Start", ev.open, ev.pend, lg)
        vw = e.read_lines(os.path.join(e.mon_dir(tmp, now), "sdr_events_verworfen.jsonl"))
        assert len(vw) == 1 and vw[0]["key"] == "n2m|floor" and vw[0]["start"] == ghost["start"], vw
        ev.update({"noise": {"t": now, "bands": [], "thunder": {}}}, now + 30)
        ev.update({"noise": {"t": now, "bands": [], "thunder": {}}}, now + 30 + 400)
        ar = e.read_lines(os.path.join(e.mon_dir(tmp, ghost["start"]), "sdr_events.jsonl"))
        assert not ar, "Geist im Ereignis-Archiv"
        W[f] = {"open": {"n2m|floor": ghost}, "pend": {}, "last": []}
        ev2 = e.EvLog(tmp, lj2, wj, now=now, tq=e.TimeQ(lambda: BADQ))
        assert "n2m|floor" in ev2.open, "ohne Uhrsync darf nichts wegen Alter verworfen werden"
        ev2.update({"noise": {"t": now, "bands": [band("rot")], "thunder": {}}}, now + 30)
        assert ev2.open["n2m|floor"]["start"] == ghost["start"], "ohne Uhrsync im Lauf verworfen"
        ev2.tq = e.TimeQ(lambda: GOOD)
        ev2.update({"noise": {"t": now, "bands": [band("rot")], "thunder": {}}}, now + 100)
        assert ev2.open["n2m|floor"]["start"] == now + 100, "Uhr spaeter synchron: Geist im Lauf nicht verworfen"
        # Uhrsprung im Lauf: Ereignis ohne Sync vor Sprung -> verworfen; synchron gestartetes bleibt bei langer Pause
        src = [BADQ]
        W2, wj2, lj3 = mk()
        tmp2 = tempfile.mkdtemp(prefix="g54j")
        ev3 = e.EvLog(tmp2, lj3, wj2, now=1787600000, tq=e.TimeQ(lambda: src[0]))
        rot = {"noise": {"t": 1, "bands": [band("rot")], "thunder": {"lvl": "gruen"}}}
        ev3.update(rot, 1787600000)
        src[0] = GOOD
        ev3.tq = e.TimeQ(lambda: src[0])
        ev3.update(rot, 1787600000 + 68 * 86400)
        assert ev3.open["n2m|floor"]["start"] == 1787600000 + 68 * 86400, ("Uhrsprung", ev3.open)
        ev3.update(rot, 1787600000 + 68 * 86400 + 2 * 3600)
        assert ev3.open["n2m|floor"]["start"] == 1787600000 + 68 * 86400, "synchron gestartetes Ereignis bei Pause > 1 h verworfen"
        ev3.update(rot, 1787600000 + 68 * 86400 + 2 * 3600 - 300)
        assert ev3.open["n2m|floor"]["start"] == 1787600000 + 68 * 86400, "Uhr zurueck verwirft synchron gestartetes Ereignis"
        shutil.rmtree(tmp2, ignore_errors=True)
        # veraltete Messung: Ende = letzte Messung
        W3, wj3, lj4 = mk()
        tmp3 = tempfile.mkdtemp(prefix="g54x")
        ev4 = e.EvLog(tmp3, lj4, wj3, now=now, tq=e.TimeQ(lambda: GOOD))
        gg = {"ok": True, "lvl": "gelb", "cls": "GPS"}
        ev4.update({"noise": {"t": now, "bands": [band("rot")], "thunder": {"lvl": "rot"}}, "gps": gg}, now)
        ev4.update({"noise": {"t": now + 600, "bands": [band("rot")], "thunder": {"lvl": "rot"}}, "gps": gg}, now + 600)
        gr = {"noise": {"t": now + 600, "stale": True, "bands": [dict(band("grau"), stale=True)], "thunder": {"lvl": "grau"}}, "gps": {"ok": True, "lvl": "gruen", "cls": "GPS"}}
        ev4.update(gr, now + 600 + 3000)
        assert ev4.pend["n2m|floor"]["end"] == now + 600 and ev4.pend["thunder"]["end"] == now + 600 and ev4.pend["gps|GPS"]["end"] == now + 3600, (ev4.pend, ev4.open)
        ev4.update({"noise": {"t": now + 4000, "bands": [band("gruen")], "thunder": {"lvl": "gruen"}}}, now + 4000)
        ev4.update({"noise": {"t": now + 4000, "bands": [band("gruen")], "thunder": {"lvl": "gruen"}}}, now + 4000 + 400)
        fin = {x["key"]: x for x in ev4.last}
        assert fin["n2m|floor"]["dur"] == 600 and fin["thunder"]["dur"] == 600, fin
        shutil.rmtree(tmp3, ignore_errors=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    with contextlib.redirect_stdout(io.StringIO()):
        e.selftest()
        s = e.selftest_evlfix()
    assert s.startswith("evlFix ok"), s
    return "Ereignislog: Normalbetrieb byte-gleich wie vorher (4 h, Neustart), Geist 1630 h ohne Sync verworfen (Nebenarchiv, nicht ins Archiv), ohne Uhrsync bleibt alles, Uhrsprung +68 d verwirft nur ungesicherte Starts, Ende veraltet = letzte Messung, Selbsttests"


NODE_RUN = r"""
var H=require('./h.js');var fs=require('fs');var SD=fs.readFileSync('sdrn.js','utf8');
SD=SD.replace(/^<script id="sdrn-js">/,'').replace(/<\/script>$/,'');var OUT={};var NOW=H.now;
function band(id,sh,ok,lvl,o){return Object.assign({id:id,short:sh,label:sh,ok:ok,lvl:lvl,t:NOW-60,floor:-40,raise:1,learning:false,n_pers:0,cars:[],why:ok?null:'KW aus',base:-41,trend:null},o||{});}
function boot(d){H.body.children=[];H.R.iv=[];H.R.fetch=[];global.location.pathname='/umwelt';H.el('div','sdrnHost');H.el('script','sdrnData',JSON.stringify(d));eval(SD);}
function card(id){return H.find(H.body,id);}
function sm(c){return H.all(c,function(n){return n.className.indexOf('small')===0;}).map(function(n){return [n.className,n.textContent];});}
function big(c){return H.all(c,function(n){return n.className==='sdrn-big';}).map(function(n){return n.textContent;});}
function run(name,d){boot(d);var q=card('sdrnQrm');OUT[name]={big:big(q),small:sm(q)};}
var T13=NOW-13*86400;
run('stale',{noise:{t:T13,qrm:{lvl:'grau',lvl_alt:'rot',stale:true},thunder:{lvl:'grau'},bands:[band('n2m','2 m',true,'grau',{lvl_alt:'rot',stale:true})],
  run:{last:T13,age_s:13*86400,next:null,iv:600,why:'Messung AUS (Lage Warnlage)',stale:true,on:false}},hist:{},now:NOW,iv:900,uf:{skip:'alt'},gps:{}});
run('stalenext',{noise:{t:T13,qrm:{lvl:'grau',stale:true},thunder:{lvl:'grau'},bands:[band('n2m','2 m',true,'grau')],
  run:{last:T13,age_s:13*86400,next:NOW+300,iv:600,why:'Meteor-Ueberflug X bald',stale:true,on:true}},hist:{},now:NOW,iv:900,gps:{}});
run('fresh',{noise:{t:NOW-120,qrm:{lvl:'gelb'},thunder:{lvl:'gruen'},bands:[band('n2m','2 m',true,'gelb')],run:{last:NOW-120,age_s:120,next:NOW+480,iv:600,why:null,stale:false,on:true}},
  hist:{},now:NOW,iv:900,gps:{}});
run('freshrun40',{noise:{t:NOW-2400,qrm:{lvl:'gruen'},thunder:{lvl:'gruen'},bands:[band('n2m','2 m',true,'gruen')],run:{last:NOW-2400,age_s:2400,next:NOW+60,iv:600,why:null,stale:false,on:true}},
  hist:{},now:NOW,iv:600,gps:{}});
run('oldfmt',{noise:{t:NOW-10*86400,qrm:{lvl:'rot'},thunder:{lvl:'gruen'},bands:[band('n2m','2 m',true,'rot')]},hist:{},now:NOW,iv:900,uf:{skip:'Planer xyz'},gps:{}});
run('none',{noise:{t:null,qrm:{lvl:'grau'},thunder:{},bands:[],run:{last:null,next:null,why:'Messung AUS (Lage Warnlage)',stale:true,on:false}},hist:{},now:NOW,iv:900,gps:{}});
console.log(JSON.stringify(OUT));
"""


def node_test(js):
    nd = shutil.which("node") or shutil.which("nodejs")
    if os.environ.get("GUARD_NO_NODE") or not nd:
        return "Seiten-Skript statisch (node fehlt)"
    d = tempfile.mkdtemp()
    try:
        for n, t in (("h.js", NODE_JS), ("run.js", NODE_RUN), ("sdrn.js", js)):
            open(os.path.join(d, n), "w", encoding="utf-8").write(t)
        o = subprocess.run([nd, "run.js"], cwd=d, capture_output=True, text=True, timeout=60)
        assert o.returncode == 0 and o.stdout.strip(), "node: " + (o.stderr or o.stdout)[-400:]
        R = json.loads(o.stdout.strip().splitlines()[-1])
    finally:
        shutil.rmtree(d, ignore_errors=True)
    S = R["stale"]
    assert S["big"] and S["big"][0].startswith("● grau – veraltet (letzte Messung vor 13 d)"), ("Ampel veraltet", S["big"])
    ln = [t for c, t in S["small"] if t.startswith("QRM steht – ")]
    assert len(ln) == 1 and "uf-old" in dict((t, c) for c, t in S["small"])[ln[0]], ("QRM steht", S["small"])
    assert "Messung alle 10 min · zuletzt " in ln[0] and "(vor 13 d)" in ln[0] and ln[0].endswith(" · Grund: Messung AUS (Lage Warnlage) · kein Termin geplant"), ln
    assert any(t == "keine Kurve – letzte Messung vor 13 d (Messung läuft nicht: Messung AUS (Lage Warnlage))" for c, t in S["small"]), ("Kurve Grund", S["small"])
    N2 = R["stalenext"]
    ln = [t for c, t in N2["small"] if t.startswith("QRM steht – ")]
    assert len(ln) == 1 and " · Grund: Meteor-Ueberflug X bald · nächster Versuch " in ln[0], ln
    F = R["fresh"]
    assert F["big"][0].startswith("● gelb – erhöht"), F["big"]
    ln = [(c, t) for c, t in F["small"] if t.startswith("Messung alle 10 min · zuletzt ")]
    assert len(ln) == 1 and " · nächste " in ln[0][1] and "uf-old" not in ln[0][0] and "veraltet" not in json.dumps(F) and "QRM steht" not in json.dumps(F), F
    F4 = R["freshrun40"]
    assert not any("uf-old" in c for c, t in F4["small"]) and F4["big"][0].startswith("● grün – ruhig"), ("40 min alt, Planer sagt frisch", F4)
    O = R["oldfmt"]
    k = [t for c, t in O["small"] if t.startswith("QRM steht – Messung alle 15 min · zuletzt ")]
    assert len(k) == 1 and k[0].endswith("(vor 10 d) · kein Termin geplant"), ("altes Format", O["small"])
    assert O["big"][0].startswith("● rot – stark gestört"), O["big"]
    Z = R["none"]
    assert Z["big"][0].startswith("● noch keine Messung"), Z["big"]
    return "Seiten-Skript mit node: veraltet -> 'grau – veraltet (letzte Messung vor 13 d)', 'QRM steht' mit Grund und naechstem Versuch, frisch -> naechste Messung ohne Warnung, Planer-Zustand hat Vorrang, altes Format weiter lesbar"


def beh_dsh(B):
    QB = "/* qrmRun */"

    def run(js, mark="/* umweltFlach */"):
        g = {"_SDRN_JS": js, "UF_MARK": mark}
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            exec(compile(B, "blk", "exec"), g)
        return g, buf.getvalue()
    g, out = run(FIX_UF)
    assert out.startswith("qrmRun aktiv: qrmRun ok") and g["_SDRN_JS"] != FIX_UF and g["_SDRN_JS"].count(QB) == 1, out
    js = g["_SDRN_JS"]
    g2 = dict(g)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g2)
    assert "qrmRun Selbsttest FEHLER" in buf.getvalue() and g2["_SDRN_JS"] == js, "doppelt geladen"
    g3, out3 = run(FIX_UF.replace("/* umweltFlach */", ""))
    assert "FEHLER" in out3 and g3["_SDRN_JS"] == FIX_UF.replace("/* umweltFlach */", ""), "ohne umweltFlach"
    br = FIX_UF.replace("var N=D.noise||{},U=D.uf||{};", "var N=D.noise||{},U=(D.uf||{});")
    assert br != FIX_UF
    g4, out4 = run(br)
    assert "FEHLER" in out4 and g4["_SDRN_JS"] == br, "nicht alles-oder-nichts"
    assert js.count("setInterval(") == FIX_UF.count("setInterval(") and js.count("fetch(") == FIX_UF.count("fetch("), "Abrufe veraendert"
    for b in JS_BAD:
        assert js.count(b) == FIX_UF.count(b), "Seiten-Skript: %s neu" % b
    for x in JS_NEED:
        assert js.count(x) == 1, "Seiten-Skript: Stelle fehlt %r" % x[:60]
    return node_test(js)


def check(altd, neud, W):
    try:
        rv = revert_all(neud, W)
    except AssertionError as e:
        fail("Rueckbau: %s" % e)
    for fn, t in rv.items():
        if t != rd(os.path.join(altd, fn)):
            fail("Rueckbau %s != Basis (Aenderung ausserhalb Block/Selbsttest-Zeile)" % fn)
    E = edits(W)
    if E["DSH_EDITS"] != [] or len(E["SDR_EDITS"]) != 1 or len(E["EVL_EDITS"]) != 1:
        fail("Stellen: dashboard nur Block, prepper_sdr/prepper_evlog je eine Selbsttest-Zeile")
    for k, want in (("SDR", "        print(selftest_qrmlage(), flush=True)\n"), ("EVL", "        print(selftest_evlfix(), flush=True)\n")):
        o, n = E["%s_EDITS" % k][0]
        if n != o + want:
            fail("%s: Stelle ist nicht nur die Selbsttest-Zeile" % k)
    st = [static(k, blk(W, k)) for k in FILES]
    tmpd = tempfile.mkdtemp(prefix="g54m")
    try:
        for side, dd in (("n", neud), ("a", altd)):
            os.makedirs(os.path.join(tmpd, side))
            for fn in ("prepper_sdr.py", "prepper_evlog.py"):
                shutil.copy(os.path.join(dd, fn), os.path.join(tmpd, side, fn))
        m = load(os.path.join(tmpd, "n", "prepper_sdr.py"), "g54_sdr_n", os.path.join(tmpd, "n"))
        ma = load(os.path.join(tmpd, "a", "prepper_sdr.py"), "g54_sdr_a", os.path.join(tmpd, "a"))
        e = load(os.path.join(tmpd, "n", "prepper_evlog.py"), "g54_evl_n", os.path.join(tmpd, "n"))
        ea = load(os.path.join(tmpd, "a", "prepper_evlog.py"), "g54_evl_a", os.path.join(tmpd, "a"))
        b1 = beh_sdr(m, ma)
        b2 = beh_evl(e, ea)
        b3 = beh_dsh(blk(W, "dsh"))
    except AssertionError as ex:
        fail("Verhalten: %s" % str(ex)[:500])
    except SystemExit:
        raise
    except Exception as ex:
        fail("Verhalten (%s): %s" % (type(ex).__name__, str(ex)[:400]))
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    print("Guard commit54 ok: Rueckbau byte-genau = Basis (3 Dateien: je ein Block, prepper_sdr/prepper_evlog je eine Selbsttest-Zeile); statisch: %s; %s; %s; %s" % ("; ".join(st), b1, b2, b3))


MUTS = [
    ("sdr", "QRL_PAUSE_MAX_S = 6 * 3600 ", "QRL_PAUSE_MAX_S = 30 * 86400 "), ("sdr", "QRL_STALE_S = 3600 ", "QRL_STALE_S = 86400 "),
    ("sdr", "QRL_HEAL_EVERY_S = 60\n", "QRL_HEAL_EVERY_S = 1\n"),
    ("sdr", "    if sw.get(\"noise\") != \"aus\" or LAGE_PROFILES[prof].get(\"noise\") == \"aus\":\n", "    if sw.get(\"noise\") != \"aus\":\n"),
    ("sdr", "now - t0 > QRL_PAUSE_MAX_S or now < t0 - 60", "now - t0 > QRL_PAUSE_MAX_S"),
    ("sdr", "                sw[\"noise\"] = LAGE_PROFILES[prof][\"noise\"]\n                r[\"sw\"], r[\"custom\"]", "                r[\"sw\"], r[\"custom\"]"),
    ("sdr", "    n[\"sw\"] = sw\n", "    n[\"sw\"] = sw\n    n[\"profile\"] = \"normal\"\n"),
    ("sdr", "    n[\"sw\"] = sw\n", ""),
    ("sdr", "    if not pz or not pz[\"expired\"]:\n        return False\n", "    if not pz:\n        return False\n"),
    ("sdr", "            keep = profile is None and src != \"noise\" and isinstance(old_off, (int, float))\n", "            keep = False\n"),
    ("sdr", "    if getattr(self, \"main\", None) is None:\n        now = time.time()", "    if True:\n        now = time.time()"),
    ("sdr", "Planner.lage_apply = _qrl_lage_apply\n", ""), ("sdr", "Planner.noise_summary = _qrl_nsum\n", ""),
    ("sdr", "    stale = t is None or age > QRL_STALE_S\n", "    stale = t is None or age > 3 * QRL_STALE_S\n"),
    ("sdr", "        if run[\"stale\"]:\n            _qrl_grey(r, run)\n", ""),
    ("sdr", "        x[\"lvl\"], x[\"stale\"], x[\"why_stale\"] = \"grau\", True, txt\n", "        x[\"stale\"], x[\"why_stale\"] = True, txt\n"),
    ("sdr", "        b[\"lvl\"], b[\"stale\"], b[\"trend\"], b[\"n_pers\"] = \"grau\", True, None, 0\n", "        b[\"lvl\"], b[\"stale\"] = \"grau\", True\n"),
    ("sdr", "            if w != m.__dict__.get(\"_qrl_w\"):\n", "            if True:\n"),
    ("sdr", "            r[\"next\"] = run[\"next\"]\n", ""),
    ("sdr", "            if nxt is None or n < nxt:\n", "            if nxt is None:\n                pass\n            if False:\n"),
    ("sdr", "            if sk and skt and now - skt < 2 * (iv or 900):\n                why = sk\n", ""),
    ("sdr", "            why = name.noise_why_off()\n", "            why = None\n"),
    ("sdr", "            if md.get(\"mode\") != \"auto\":\n", "            if False:\n"),
    ("sdr", "        if self is m:\n", "        if self is m:\n            m.cfg[\"noise_enable\"] = True\n"),
    ("sdr", "    write_json(p(\"sdr_lage.json\", base), n)\n", "    write_json(p(\"sdr_lage.json\", base), n)\n    write_json(p(\"sdr_config.json\", base), {})\n"),
    ("sdr", "QRL_HEAL_EVERY_S = 60\n", "QRL_HEAL_EVERY_S = 60\nimport subprocess\n"),
    ("sdr", "                m.__dict__[\"_qrl_w\"] = w\n", "                m.__dict__[\"_qrl_w\"] = w\n                send_meshtastic(\"QRM steht\")\n"),
    ("evl", "EVF_GHOST_S = 86400 ", "EVF_GHOST_S = 90 * 86400 "), ("evl", "EVF_JUMP_S = 3600 ", "EVF_JUMP_S = 360000 "),
    ("evl", "    if synced and not (e.get(\"start_tq\") or {}).get(\"sync\") and", "    if not (e.get(\"start_tq\") or {}).get(\"sync\") and"),
    ("evl", "    if st > now + EVF_FUT_S:\n", "    if st > now + 10 * EVF_FUT_S * 100:\n"),
    ("evl", "lambda e: why if (not (e.get(\"start_tq\") or {}).get(\"sync\") or e[\"start\"] > now) else None", "lambda e: why"),
    ("evl", "        if _fin(prev) and (now - prev > EVF_JUMP_S or now < prev - EVF_BACK_S):\n", "        if False:\n"),
    ("evl", "os.path.join(mon_dir(self.base, now), \"sdr_events_verworfen.jsonl\")", "os.path.join(mon_dir(self.base, now), \"sdr_events.jsonl\")"),
    ("evl", "    self.last = keep\n", ""),
    ("evl", "                    e[\"end\"], e[\"note\"] = int(nt), \"Ende = letzte Messung (danach keine QRM-Messung)\"\n", "                    pass\n"),
    ("evl", "and not k.startswith(\"gps|\")", ""), ("evl", "EvLog.update = _evf_update\n", ""), ("evl", "EvLog.__init__ = _evf_init\n", ""),
    ("evl", "        self.evf[\"dropped\"] += _evf_drop(self, now, lambda e: _evf_bad(e, now, syn), \"beim Start\")\n", "        pass\n"),
    ("evl", "    f[\"t_prev\"] = now\n", ""),
    ("evl", "        if now - f.get(\"chk\", 0) >= EVF_CHECK_S or now < f.get(\"chk\", 0):\n", "        if False:\n"),
    ("dsh", "if(N.run&&typeof N.run.stale==='boolean')return N.run.stale;", ""),
    ("dsh", "grau:(N.t&&ufStale()?'grau – veraltet (letzte Messung vor '+ufAge(N.t)+')':'noch keine Messung')}", "grau:'noch keine Messung'}"),
    ("dsh", "(o?'QRM steht – ':'')+", ""), ("dsh", "+(o&&R.why?' · Grund: '+R.why:'')", ""), ("dsh", "(o?' · nächster Versuch ':' · nächste ')", "' · nächste '"),
    ("dsh", "U={skip:(N.run||{}).why||(D.uf||{}).skip}", "U=D.uf||{}"),
    ("dsh", "            raise ValueError(\"%s: Stelle %d nicht genau einmal (%d)\" % (tag, i + 1, js.count(o)))", "            continue"),
    ("dsh", "(R.next?", "(R.next&&!o?"), ("dsh", "+')':'noch keine Messung')}", "+')'+'<b>'.innerHTML:'noch keine Messung')}"),
    ("dsh", "    _SDRN_JS = _qr_s\n", "    _SDRN_JS = _qr_s\n    app.view_functions.pop('sdrn_api', None)\n"),
]


def mutate(altd, neud, W):
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    E = edits(W)
    try:
        def run(files, blks, etxt):
            nd, wd = os.path.join(d, "n"), os.path.join(d, "w")
            for x in (nd, wd):
                shutil.rmtree(x, ignore_errors=True)
                os.makedirs(x)
            for fn, t in files.items():
                open(os.path.join(nd, fn), "w", encoding="utf-8").write(t)
            for k, t in blks.items():
                open(os.path.join(wd, "blk_%s.py" % k), "w", encoding="utf-8").write(t)
            open(os.path.join(wd, "edits.py"), "w", encoding="utf-8").write(etxt)
            o = subprocess.run([sys.executable, me, "check", altd, nd, wd], capture_output=True, text=True, timeout=600)
            return o.returncode != 0, [x[:160] for x in ((o.stdout + o.stderr).strip().splitlines() or [""])[-1:]]
        files = {fn: rd(os.path.join(neud, fn)) for fn, _ in FILES.values()}
        blks = {k: blk(W, k) for k in FILES}
        etxt = rd(os.path.join(W, "edits.py"))
        bad, msg = run(files, blks, etxt)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for k, a, b in MUTS:
            if blks[k].count(a) < 1:
                print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70]))
                missed += 1
                continue
            bm = blks[k].replace(a, b, 1)
            fn = FILES[k][0]
            fm = dict(files)
            fm[fn] = files[fn].replace("\n\n" + blks[k].rstrip("\n") + ANCH, "\n\n" + bm.rstrip("\n") + ANCH, 1)
            assert fm[fn] != files[fn]
            cases.append(("%s %s" % (k, a[:50]), fm, dict(blks, **{k: bm}), etxt))
        f2 = dict(files)
        f2["prepper_sdr.py"] = files["prepper_sdr.py"].replace("QRL_PAUSE_MAX_S = 6 * 3600 ", "QRL_PAUSE_MAX_S = 9 * 3600 ", 1)
        cases.append(("Datei weicht vom Block ab", f2, blks, etxt))
        f3 = dict(files)
        f3["prepper_sdr.py"] = files["prepper_sdr.py"].replace("\n        print(selftest_qrmlage(), flush=True)\n", "\n", 1)
        cases.append(("Selbsttest-Zeile fehlt", f3, blks, etxt))
        f4 = dict(files)
        f4["prepper_evlog.py"] = files["prepper_evlog.py"].replace("STALE_S = 1800 ", "STALE_S = 18000 ", 1)
        cases.append(("Zeile ausserhalb prepper_evlog", f4, blks, etxt))
        f5 = dict(files)
        f5["dashboard.py"] = files["dashboard.py"].replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1)
        assert f5["dashboard.py"] != files["dashboard.py"]
        cases.append(("Zeile ausserhalb dashboard", f5, blks, etxt))
        f6 = dict(files)
        f6["prepper_sdr.py"] = files["prepper_sdr.py"].replace("def set_lage(base, profile=None, src=None, state=None):\n    \"\"\"Vom Dashboard", "def set_lage(base, profile=None, src=None, state=\"aus\"):\n    \"\"\"Vom Dashboard", 1)
        assert f6["prepper_sdr.py"] != files["prepper_sdr.py"]
        cases.append(("Zeile ausserhalb prepper_sdr (Lage)", f6, blks, etxt))
        f7 = dict(files)
        f7["dashboard.py"] = files["dashboard.py"].replace(ANCH, "\n\n" + blks["dsh"].rstrip("\n") + ANCH, 1)
        cases.append(("Block doppelt", f7, blks, etxt))
        e8 = etxt.replace("print(selftest_qrmlage(), flush=True)\\n\")]", "print(selftest_qrmlage(), flush=True)\\n        selftest_sqlb()\\n\")]", 1)
        assert e8 != etxt
        f8 = dict(files)
        f8["prepper_sdr.py"] = files["prepper_sdr.py"].replace("        print(selftest_qrmlage(), flush=True)\n", "        print(selftest_qrmlage(), flush=True)\n        selftest_sqlb()\n", 1)
        cases.append(("Selbsttest-Stelle erweitert", f8, blks, e8))
        for name, fm, bm, et in cases:
            bad, msg = run(fm, bm, et)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest commit54: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed,
          " (ohne node)" if os.environ.get("GUARD_NO_NODE") or not (shutil.which("node") or shutil.which("nodejs")) else " (mit node)"))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    md = sys.argv[1]
    if md == "revert":
        os.makedirs(sys.argv[3], exist_ok=True)
        for fn, t in revert_all(sys.argv[2], sys.argv[4]).items():
            open(os.path.join(sys.argv[3], fn), "w", encoding="utf-8").write(t)
        print("Rueckbau commit54 ok")
    elif md == "check":
        check(*sys.argv[2:5])
    elif md == "mutate":
        mutate(*sys.argv[2:5])
MK_C54_GRD_EOF
EMB="patch.py:$EXPECT_PAT edits.py:$EXPECT_EDI G/blk_dsh.py:$EXPECT_BDS G/blk_sdr.py:$EXPECT_BSD G/blk_evl.py:$EXPECT_BEV guard.py:$EXPECT_GRD"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
cp "$W/edits.py" "$W/G/edits.py"
echo "OK eingebettete Dateien geprueft (6: Patcher, Stellen, 3 Bloecke, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "$2"; return; }; shift 2; done; echo UNBEKANNT; }
# ---------- 1) Basis: dashboard.py, prepper_sdr.py, prepper_evlog.py gemeinsam alt oder neu; lage_pages.py fest ----------
for x in "$F" "$FL" "$FS" "$FE"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS"); E16=$(s16 "$FE")
SD=$(lbl "$D16" "$KNOWN_D16" alt "$KNOWN_D16N" neu); SS=$(lbl "$S16" "$KNOWN_S16" alt "$KNOWN_S16N" neu); SE=$(lbl "$E16" "$KNOWN_E16" alt "$KNOWN_E16N" neu)
echo "Basis dashboard.py     sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit53, neu $KNOWN_D16N)"
echo "Basis prepper_sdr.py   sha16 $S16 ($(wc -l < "$FS") Zeilen) - $SS (alt $KNOWN_S16, neu $KNOWN_S16N)"
echo "Basis prepper_evlog.py sha16 $E16 ($(wc -l < "$FE") Zeilen) - $SE (alt $KNOWN_E16, neu $KNOWN_E16N)"
echo "Basis lage_pages.py    sha16 $L16 - $([[ "$L16" == "$KNOWN_L16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C52" || "$D16" == "$KNOWN_D16_C51" || "$D16" == "$KNOWN_D16_C50" || "$L16" == "$KNOWN_L16_C52" ]]; then
  WAS="nach commit52"; [[ "$D16" == "$KNOWN_D16_C51" ]] && WAS="nach commit51 (commit52 fehlt auch)"; [[ "$D16" == "$KNOWN_D16_C50" ]] && WAS="nach commit50 (commit51 und commit52 fehlen auch)"
  echo "STOP: erst commit53 anwenden - dashboard.py/lage_pages.py sind noch der Stand $WAS (dashboard.py $D16, lage_pages.py $L16), commit54 braucht dashboard.py $KNOWN_D16 und lage_pages.py $KNOWN_L16 (nach commit53) - nichts geaendert."
  exit 1
fi
for v in "dashboard.py:$SD:$D16" "prepper_sdr.py:$SS:$S16" "prepper_evlog.py:$SE:$E16"; do
  IFS=: read -r fn st hh <<< "$v"
  if [[ "$st" == UNBEKANNT ]]; then
    echo "STOP: $fn weicht vom erwarteten Stand ab (sha16 $hh) - nichts geaendert."
    echo "      commit54 passt nur auf den Stand nach commit53. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
    exit 1
  fi
done
if [[ "$SD$SS$SE" != altaltalt && "$SD$SS$SE" != neuneuneu ]]; then
  echo "STOP: Mischstand (dashboard.py $SD, prepper_sdr.py $SS, prepper_evlog.py $SE) - erwartet alle drei alt oder alle drei neu - nichts geaendert."
  for x in "$F" "$FS" "$FE"; do LBX=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $LBX ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  exit 1
fi
[[ "$L16" == "$KNOWN_L16" ]] || stop "lage_pages.py ist nicht der Stand nach commit53 ($L16 statt $KNOWN_L16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" && -w "$FS" && -w "$FE" ]] || stop "Projektordner, dashboard.py, prepper_sdr.py oder prepper_evlog.py ist nicht beschreibbar"
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
# ---- Neustart-Sperre HH:55-HH:04 (Berlin); geprueft jetzt, vor dem Ersetzen und fuer die naechsten 300 s (zwei Dienste) ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C54_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C54_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 300)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04, Vorlauf 5 min) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit54 ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - Sperre HH:55-HH:04 (mit 5 min Vorlauf: Start ab HH:50 gesperrt) - prepper-sdr und prepper-dashboard werden jetzt nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04, auch in 5 min ($1)"; fi; }
rscheck "Vorpruefung"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" || "$f" == "$FS" || "$f" == "$FE" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch lage_pages.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
PT() { python3 "$W/patch.py" "$1" "$2" "$3" "$4" "$W/G/blk_$2.py" "$W/edits.py"; }
PT qrmRun dsh "$F" "$W/work/dashboard.py" > "$W/q1.log" || { cat "$W/q1.log"; stop "dashboard.py: Stelle fuer qrmRun nicht eindeutig"; }
PT qrmLage sdr "$FS" "$W/work/prepper_sdr.py" > "$W/q2.log" || { cat "$W/q2.log"; stop "prepper_sdr.py: Stelle fuer qrmLage nicht eindeutig"; }
PT evlFix evl "$FE" "$W/work/prepper_evlog.py" > "$W/q3.log" || { cat "$W/q3.log"; stop "prepper_evlog.py: Stelle fuer evlFix nicht eindeutig"; }
for v in "dashboard.py:$KNOWN_D16N" "prepper_sdr.py:$KNOWN_S16N" "prepper_evlog.py:$KNOWN_E16N"; do
  IFS=: read -r fn hh <<< "$v"
  [[ "$(s16 "$W/work/$fn")" == "$hh" ]] || stop "Ergebnis $fn $(s16 "$W/work/$fn") statt $hh (Zielstand nicht erreicht)"
done
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(cat "$W/q1.log")), prepper_sdr.py $KNOWN_S16N ($(cat "$W/q2.log")), prepper_evlog.py $KNOWN_E16N ($(cat "$W/q3.log"))"
PT x dsh "$W/work/dashboard.py" "$W/work/x1" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
PT x sdr "$W/work/prepper_sdr.py" "$W/work/x2" > /dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/x2" || stop "prepper_sdr.py nicht idempotent"
PT x evl "$W/work/prepper_evlog.py" "$W/work/x3" > /dev/null && cmp -s "$W/work/prepper_evlog.py" "$W/work/x3" || stop "prepper_evlog.py nicht idempotent"
rm -f "$W/work/x1" "$W/work/x2" "$W/work/x3"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/prepper_sdr.py" "$W/work/prepper_evlog.py" "$W/patch.py" "$W/edits.py" "$W/G/blk_dsh.py" "$W/G/blk_sdr.py" "$W/G/blk_evl.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/work/prepper_sdr.py" "$W/work/prepper_evlog.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/G" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: commit54 im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/prepper_sdr.py")" == "$KNOWN_S16" && "$(s16 "$W/alt/prepper_evlog.py")" == "$KNOWN_E16" ]] || stop "Guard: Stand ohne commit54 ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt" "$W/neu" "$W/G" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard commit54 meldet Verstoss"; }
grep "^Guard commit54" "$W/g.log" | cut -c1-2000
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Seiten-Skript hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C54_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/G" > "$W/gm.log" 2>&1 || { cat "$W/gm.log"; stop "Mutationstest commit54: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gm.log"
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
# QRM-Zustand aus /api/sdr/noise: t(letzte Messung) lvl run(0/1) stale next why
nzst() { "${CURL[@]}" "$B/api/sdr/noise" 2>/dev/null | python3 -c 'import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    print("0 FEHLER 0 - 0 -"); sys.exit(0)
n = d.get("noise") or {}
r = n.get("run") if isinstance(n.get("run"), dict) else None
w = ((r or {}).get("why") or (d.get("uf") or {}).get("skip") or "-").replace(" ", "_")[:120]
print(int(n.get("t") or 0), (n.get("qrm") or {}).get("lvl") or "-", 1 if r else 0, int(bool((r or {}).get("stale"))), int((r or {}).get("next") or 0), w)' 2>/dev/null || echo "0 FEHLER 0 - 0 -"; }
hmt() { if [[ "${1:-0}" -gt 0 ]]; then TZ=Europe/Berlin date -d "@$1" "+%d.%m. %H:%M"; else echo "-"; fi; }
lagest() { python3 - "$DLA" << 'MK_C54_LAGE'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("fehlt - -"); sys.exit(0)
sw = d.get("sw") if isinstance(d.get("sw"), dict) else {}
print(d.get("profile") or "-", sw.get("noise") or "-", "heal" if d.get("noise_heal_at") else "-")
MK_C54_LAGE
}
read -r BR_S0 BR_H0 BR_G0 <<< "$(brst)"
T4L0=$(t4lv)
TLAT0=$(tmed "$B/api/t4/status")
read -r NZT0 NZL0 NZR0 NZS0 NZN0 NZW0 <<< "$(nzst)"
read -r LP0 LN0 LH0 <<< "$(lagest)"
echo "Zustand vorher: BR24 $BR_S0, Lage-Ampel (teil4) $T4L0, teil4 aktiv $T4OK0 (Takt $T4N0), /api/t4/status Median ${TLAT0} s"
echo "QRM vorher: letzte Messung $(hmt "$NZT0"), Ampel $NZL0, Lage-Datei: Profil $LP0, QRM-Schalter $LN0$([[ "$NZW0" != - ]] && echo ", Grund: $(echo "$NZW0" | tr '_' ' ')")"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: commit54 ist schon installiert - ein echter Lauf aendert an den Dateien nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py, prepper_sdr.py, prepper_evlog.py ersetzen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST; dazu sdr_events.json und sdr_lage.json gesichert), prepper-sdr und prepper-dashboard neu starten, 26 Seiten/APIs und Journal pruefen, bis 20 min auf eine QRM-Messung warten, eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer die Neustarts und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED=0
T0D=$(date +%s)
INST=()
DATA=()
waitd() { local i; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
waits() { local i st0="$1"; for i in $(seq 1 60); do sleep 2; if systemctl is-active --quiet prepper-sdr; then [[ -f "$DASH_DIR/sdr_status.json" && "$(stat -c %Y "$DASH_DIR/sdr_status.json")" -gt "$st0" ]] && return 0; fi; done; return 1; }
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-sdr --since "@${T0D:-0}" --no-pager -n 400 -o cat | grep -E "qrmLage|qrmRun|evlFix|Traceback|Planer-Fehler|Ereignis-Log" | tail -6 | cut -c1-240
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -n 400 -o cat | grep -E "qrmRun|umweltFlach|Traceback" | tail -4 | cut -c1-240
  local x
  if [[ "$RESTARTED" == 1 ]]; then sudo systemctl stop prepper-sdr.service; fi
  local RBF=("${INST[@]}")
  [[ "$RESTARTED" == 1 ]] && RBF+=("${DATA[@]}")
  for x in "${RBF[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  for x in "${RBF[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  if [[ "$RESTARTED" == 1 ]]; then
    sudo systemctl start prepper-sdr.service
    sudo systemctl restart prepper-dashboard.service
    waitd
  fi
  echo "  Datenbank, lage_pages.py und Mesh-Regeln wurden nicht veraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK commit54 schon installiert - kein Neustart, keine Aenderung an den Dateien"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen"
  for x in "$F" "$FS" "$FE" "$DEV" "$DLA"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-$NM-$TS"
    { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  for x in "$DEV" "$DLA"; do [[ -f "$x.bak-$NM-$TS" ]] && DATA+=("$x"); done
  echo "OK Sicherungen *.bak-$NM-$TS: dashboard.py, prepper_sdr.py, prepper_evlog.py$(for x in "${DATA[@]}"; do printf ', %s' "$(basename "$x")"; done) (behalten: letzte $KEEP_LAST)"
  for v in "$FE:prepper_evlog.py:$KNOWN_E16N" "$FS:prepper_sdr.py:$KNOWN_S16N" "$F:dashboard.py:$KNOWN_D16N"; do
    IFS=: read -r x fn hh <<< "$v"
    INST+=("$x")
    cp "$W/work/$fn" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rb "$fn installieren"; exit 1; }
    [[ "$(s16 "$x")" == "$hh" ]] || { rb "$fn nach dem Kopieren falsch ($(s16 "$x"))"; exit 1; }
  done
  echo "OK prepper_evlog.py, prepper_sdr.py, dashboard.py atomar ersetzt"
  RESTARTED=1
  T0D=$(date +%s)
  ST0=$(stat -c %Y "$DASH_DIR/sdr_status.json" 2>/dev/null || echo 0); [[ "$ST0" -lt "$T0D" ]] || ST0=$T0D
  echo "Neustart prepper-sdr (Planer, Ereignislog) - warte bis aktiv und Status neu geschrieben (max 120 s) ..."
  sudo systemctl restart prepper-sdr.service
  waits "$ST0" || { rb "prepper-sdr nach dem Neustart nicht aktiv oder schreibt keinen Status (120 s)"; exit 1; }
  echo "OK prepper-sdr aktiv, Status neu ($(TZ=Europe/Berlin date -d "@$(stat -c %Y "$DASH_DIR/sdr_status.json")" +%H:%M:%S))"
  echo "Neustart prepper-dashboard - warte auf HTTP 200 (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  waitd || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
PHASE=Pruefung
# ---------- 5) Pruefung ----------
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher (alle $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
T4OK=0
for i in $(seq 1 30); do
  read -r T4OK1 T4N1 T4TH1 HBL1 <<< "$(t4st)"
  [[ "$T4OK1" == 1 && "$T4N1" -ge 3 ]] && { T4OK=1; break; }
  sleep 4
done
[[ "$T4OK" == 1 ]] || rbx "teil4 nach dem Neustart nicht aktiv oder Takt steht (ok $T4OK1, Takt $T4N1, Faden $T4TH1)"
sleep 6; read -r T4OK2 T4N2 T4TH2 HBL2 <<< "$(t4st)"
[[ "$T4N2" -gt "$T4N1" ]] || rbx "teil4-Takt laeuft nicht weiter ($T4N1 -> $T4N2)"
echo "OK teil4 aktiv, Takt laeuft ($T4N1 -> $T4N2 in 6 s)"
TLAT1=$(tmed "$B/api/t4/status")
echo "OK /api/t4/status Median ${TLAT1} s (vorher ${TLAT0} s)"
awk -v a="$TLAT0" -v b="$TLAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/api/t4/status ist deutlich langsamer geworden (${TLAT0} s -> ${TLAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200)"
for v in "$F:qrmRun" "$FS:qrmLage" "$FE:evlFix"; do
  IFS=: read -r x mk <<< "$v"
  n=$(grep -c "^# ===== $mk:" "$x" || true)
  [[ "$n" == 1 ]] || rbx "$(basename "$x") Marker $mk ${n}x"
done
echo "OK Marker qrmRun (dashboard.py), qrmLage (prepper_sdr.py), evlFix (prepper_evlog.py) je 1x"
for i in $(seq 1 20); do
  UH=$("${CURL[@]}" "$B/umwelt" -o "$W/umwelt.html" -w "%{http_code}" || true)
  UQ=$(grep -c "/\* qrmRun \*/" "$W/umwelt.html" || true)
  [[ "$UH" == 200 && "$UQ" == 1 ]] && break
  sleep 3
done
[[ "$UH" == 200 ]] || rbx "/umwelt HTTP $UH"
[[ "$UQ" == 1 ]] || rbx "/umwelt ohne qrmRun-Skript (${UQ}x, 60 s gewartet)"
echo "OK /umwelt mit qrmRun-Anzeige (veraltet grau, QRM steht mit Grund, naechste Messung)"
RUNOK=0
for i in $(seq 1 30); do read -r NZT1 NZL1 NZR1 NZS1 NZN1 NZW1 <<< "$(nzst)"; [[ "$NZR1" == 1 ]] && { RUNOK=1; break; }; sleep 4; done
[[ "$RUNOK" == 1 ]] || rbx "/api/sdr/noise ohne Planer-Zustand noise.run (prepper-sdr neu?)"
echo "OK /api/sdr/noise mit Planer-Zustand: letzte Messung $(hmt "$NZT1"), Ampel $NZL1, $([[ "$NZS1" == 1 ]] && echo "QRM steht (veraltet, grau)" || echo "aktuell"), naechste Messung $(hmt "$NZN1")$([[ "$NZW1" != - ]] && echo ", Grund: $(echo "$NZW1" | tr '_' ' ')")"
read -r LP1 LN1 LH1 <<< "$(lagest)"
[[ "$LP1" == "$LP0" ]] || rbx "Lage-Profil hat sich geaendert ($LP0 -> $LP1)"
if [[ "$LN0" == aus && "$LP0" != ruhe ]]; then
  for i in $(seq 1 45); do read -r LP1 LN1 LH1 <<< "$(lagest)"; [[ "$LN1" != aus ]] && break; sleep 2; done
  [[ "$LN1" != aus ]] && echo "OK Lage-Datei bereinigt: Profil $LP1 bleibt, QRM-Schalter $LN0 -> $LN1 (abgelaufene Pause entfernt, Sicherung sdr_lage.json.bak-$NM-$TS)" || echo "HINWEIS QRM-Schalter steht noch auf AUS (Pause juenger als 6 h? dann laeuft sie spaeter von selbst ab)"
else echo "OK Lage-Datei: Profil $LP1, QRM-Schalter $LN1 (keine Pause zu bereinigen)"; fi
read -r BR_S1 BR_H1 BR_G1 <<< "$(brst)"
T4L1=$(t4lv)
[[ "$BR_S1" != FEHLER && "$T4L1" != FEHLER ]] || rbx "/api/br24 oder /api/t4/status nicht lesbar ($BR_S1 / $T4L1)"
echo "OK Zustand nachher: BR24 $BR_S1 (vorher $BR_S0), Lage-Ampel $T4L1 (vorher $T4L0)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -n 3000 -o cat || true)
JS=$(jc -u prepper-sdr --since "@$T0D" --no-pager -n 3000 -o cat || true)
echo "$JD" > "$W/jd.txt"; echo "$JS" > "$W/js.txt"
if [[ -z "$(echo "$JD$JS" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-sdr -n 300 --no-pager | grep -E qrm"
else
  if [[ "$RESTARTED" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "qrmRun aktiv: qrmRun ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-200)" || rbx "Journal prepper-dashboard ohne 'qrmRun aktiv: qrmRun ok' ($(echo "$JD" | grep -F qrmRun | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok' 'kartePop aktiv: kartePop ok' 'hbProblem aktiv: hbProblem ok' 'umweltFlach aktiv: umweltFlach ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
    JST=$(echo "$JS" | grep -E "Start v[0-9]+" | tail -1 || true)
    [[ -n "$JST" ]] && echo "OK Journal prepper-sdr: $(echo "$JST" | cut -c1-160)" || echo "HINWEIS Journal prepper-sdr ohne Startzeile (Ausgabe anders?)"
  fi
  E2=$(echo "$JD" | grep -c -E 'qrmRun Selbsttest FEHLER|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'qrmRun Selbsttest FEHLER|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E4=$(echo "$JS" | grep -c -E 'qrmRun noise_summary:|qrmLage get_lage:|qrmLage set_lage:|qrmLage: [^Q]|evlFix (Start|Nebenarchiv|Ende):|evlFix: [^0-9]|Ereignis-Log' || true)
  [[ "${E4:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Fehler von qrmLage/qrmRun/evlFix, ohne Planer-Fehler und Traceback" || { echo "$JS" | grep -E 'qrmRun noise_summary:|qrmLage get_lage:|qrmLage set_lage:|qrmLage: [^Q]|evlFix (Start|Nebenarchiv|Ende):|evlFix: [^0-9]|Ereignis-Log' | cut -c1-240; rbx "$E4 Fehlerzeile(n) im Journal prepper-sdr"; }
  E5=$(echo "$JS" | grep -c -E 'Traceback|Planer-Fehler' || true)
  [[ "${E5:-0}" == 0 ]] || { echo "HINWEIS Journal prepper-sdr seit Neustart: $E5 Zeile(n) mit Traceback/Planer-Fehler (nicht von commit54; bitte ansehen, wenn dauerhaft):"; echo "$JS" | grep -E 'Traceback|Planer-Fehler' | tail -5 | cut -c1-200 | sed 's/^/   | /'; }
  echo "$JS" | grep -E 'qrmLage:|qrmRun:|evlFix:' | tail -4 | cut -c1-230 | sed 's/^/  Journal prepper-sdr: /' || true
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein commit54-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ ( "$u" == prepper-dashboard || "$u" == prepper-sdr ) && "$RESTARTED" == 1 ]]; then [[ "$a" == active ]] || rbx "$u laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- neu gestartet: $([[ "$RESTARTED" == 1 ]] && echo "prepper-sdr und prepper-dashboard" || echo "keiner"); Mesh-Bruecken unveraendert"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter lage_pages.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Mesh-Regeln (echte Alarme 6 h Dublettenschutz, max 3/h), Gain-Waechter (Stufe 16), lage_pages.py und Mesh-Bruecken unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) QRM-Messung abwarten (hoechstens 20 min, kein Fehler) ----------
if [[ "$RESTARTED" == 1 ]]; then
  echo "Warte auf eine neue QRM-Messung (hoechstens $((MEAS_WAIT / 60)) min; Abbruch mit Strg+C ist harmlos - alles ist schon installiert und geprueft) ..."
  TW0=$(date +%s); MEAS=0; LASTP=0; NOPLAN=0
  while :; do
    read -r NZT2 NZL2 NZR2 NZS2 NZN2 NZW2 <<< "$(nzst)"
    if [[ "$NZT2" -gt "$NZT0" && "$NZT2" -ge "$T0D" ]]; then MEAS=1; break; fi
    now=$(date +%s)
    [[ $((now - TW0)) -ge "$MEAS_WAIT" ]] && break
    if [[ "$NZN2" -gt 0 && "$NZN2" -gt $((TW0 + MEAS_WAIT + 300)) ]]; then break; fi
    if [[ "$NZR2" == 1 && "$NZN2" == 0 ]]; then NOPLAN=$((NOPLAN + 1)); [[ "$NOPLAN" -ge 9 ]] && break; else NOPLAN=0; fi
    if [[ $((now - LASTP)) -ge 300 ]]; then echo "  ... $(TZ=Europe/Berlin date +%H:%M) noch keine neue Messung, naechste geplant $(hmt "$NZN2")$([[ "$NZW2" != - ]] && echo " ($(echo "$NZW2" | tr '_' ' '))")"; LASTP=$now; fi
    sleep 20
  done
  if [[ "$MEAS" == 1 ]]; then echo "OK QRM-Messung gelaufen: $(hmt "$NZT2") Uhr (Berlin), Ampel jetzt $NZL2, naechste $(hmt "$NZN2")"
  else echo "HINWEIS noch keine neue QRM-Messung seit dem Neustart - $([[ "$NZN2" -gt 0 ]] && echo "naechste Messung um $(hmt "$NZN2") Uhr (Berlin)" || echo "derzeit keine Messung geplant")$([[ "$NZW2" != - ]] && echo ", Grund: $(echo "$NZW2" | tr '_' ' ')"). Kein Fehler: die Seite /umwelt zeigt den Stand; Pruefen spaeter: curl -s http://127.0.0.1:$PORT/api/sdr/noise"; fi
fi
# ---------- 9) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F") ($(wc -l < "$F") Zeilen), prepper_sdr.py sha16 $(s16 "$FS") ($(wc -l < "$FS") Zeilen), prepper_evlog.py sha16 $(s16 "$FE") ($(wc -l < "$FE") Zeilen), lage_pages.py sha16 $(s16 "$FL")"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1); LBS=$({ ls -1t "$FS.bak-$NM-"* 2>/dev/null || true; } | head -1); LBE=$({ ls -1t "$FE.bak-$NM-"* 2>/dev/null || true; } | head -1)
if [[ -n "$LB" && -n "$LBS" && -n "$LBE" ]]; then
  echo "Rueckweg (alle drei zusammen, Daten optional):"
  echo "  sudo systemctl stop prepper-sdr && cp -a $LB $F && cp -a $LBS $FS && cp -a $LBE $FE && sudo systemctl start prepper-sdr && sudo systemctl restart prepper-dashboard"
  LBV=$({ ls -1t "$DEV.bak-$NM-"* 2>/dev/null || true; } | head -1); LBA=$({ ls -1t "$DLA.bak-$NM-"* 2>/dev/null || true; } | head -1)
  [[ -n "$LBV$LBA" ]] && echo "  alte Daten (nur bei Bedarf, bei gestopptem prepper-sdr): $([[ -n "$LBV" ]] && echo "cp -a $LBV $DEV ")$([[ -n "$LBA" ]] && echo "cp -a $LBA $DLA")"
else echo "Rueckweg: keine $NM-Sicherung vorhanden (Dateien nicht geaendert)"; fi
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c qrmLage /home/fmg/prepper-dashboard/prepper_sdr.py"
echo "  sudo journalctl -u prepper-sdr -n 300 --no-pager | grep -E qrm"
echo "  curl -s http://127.0.0.1:5000/api/sdr/noise | grep -o .run.:....................................................."
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Beim Einspielen nichts gesendet (kein Mesh, kein Telegram, keine Alarme), keine andere Einstellung und keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
