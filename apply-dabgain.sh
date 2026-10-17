#!/bin/bash
set -euo pipefail
# dabGain (auf dabFix): DAB im Zwei-Stick-Betrieb (welle-cli ueber rtl_tcp) mit fester Verstaerkung welle-cli -g STUFE (40,2 dB = Stufe 22, R820T)
# statt welle-Software-AGC, Leiter 40,2/32,8/44,5/28,0/49,6 dB/AGC bei fehlendem Sync; Sync nur bei echtem Ensemble (Kennung/Name/Dienste,
# fct0 != lastchannelchange); DAB ohne Sync zaehlt nicht mehr als empfangen (BR24/ASA ehrlich); noise_fm_known 96.25/100.15/107.2 in sdr_config.json.
# Nur prepper_sdr.py + sdr_config.json, Neustart nur prepper-sdr. Sendet nichts, kein Mesh, keine neuen Sockets/Server/Faeden.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
C="$DASH_DIR/sdr_config.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/dabgain-apply
KEEP_LAST=3
KNOWN_SDR16="fd75aec5167b994e"   # live nach dabFix (5442 Zeilen)
KNOWN_DASH16="eae4f12e3a71bdd2"  # live nach lageGeo (bleibt unveraendert)
DAB_WAIT_S="${DAB_WAIT_S:-1500}"  # danach: auf DAB-Pruefung + Stoerer-Messung warten und Werte zeigen (nur Anzeige, kein Rollback)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== dabGain apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_BLK="b7cb67dc1159aa646691d89152d3129b464e2fdacbb4b5b9b5f8b26d96226e9f"
cat > "$W/dg_sdr_block.py" << 'DGSDR_EOF'
# ===== dabGain: DAB ueber rtl_tcp (Zwei-Stick-Betrieb) mit fester Verstaerkung statt welle-Software-AGC, Sync nur bei echtem Ensemble, DAB-Empfang ehrlich; nur Empfang =====
# welle-cli 2.4 ueber rtl_tcp: ohne -g regelt welle selbst (Software-AGC) und schickt beim Verbinden Gain-Befehle an rtl_tcp - ein rtl_tcp -g wird
# damit ueberschrieben. welle-cli -g erwartet eine STUFE (Index der Tunertabelle), keine dB: R820T/R820T2 (NESDR SMArt v5) 29 Stufen, Stufe 22 = 40,2 dB.
# Ablauf: Stufe aus gain_dab_db (Standard 40 dB) -> -g Index nur am rtl_tcp-Weg und nur wenn gain_dab (Index, wie bisher) nicht gesetzt ist.
# Kein Sync in 2 DAB-Pruefungen hintereinander -> naechste Stufe der Leiter 40,2 / 32,8 / 44,5 / 28,0 / 49,6 dB / welle-AGC, dann von vorn.
# Sync bringt die Stufe als "ok" (je Stick-SN in broadcast_state.json dabgain). Kalibrierung bekommt nur eine bewiesene ok-Stufe.
# Sync gilt nur, wenn das Ensemble echt ist (Kennung != 0x0000 oder Name oder Dienste) und time_last_fct0_frame != lastchannelchange.
# DAB-Kanal ohne Sync: t/Ensemble/Dienste bleiben auf dem letzten echten Empfang (BR24/ASA zeigen DAB nicht mehr als empfangen),
# dazu rx False, try_t, nosync_n, rx_why.
R82XX_GAINS = (0.0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9, 25.4, 28.0, 29.7, 32.8, 33.8, 36.4, 37.2, 38.6, 40.2,
               42.1, 43.4, 43.9, 44.5, 48.0, 49.6)
DABGAIN_LADDER = (40.2, 32.8, 44.5, 28.0, 49.6, "agc")
DABGAIN_FAIL_N = 2
DABGAIN_MIN_S = 20
_dg_orig_parse = dabfix_parse
_dg_orig_cmd_dab = Planner._cmd_dab
_dg_orig_cmd_cal = Planner._cmd_cal
_dg_orig_on_dab = StateBC.on_dab
_dg_orig_sub_done = Planner.sub_done


def dabgain_index(db):
    """dB -> naechste R820T-Stufe (Index fuer welle-cli -g)."""
    d = _dfnum(db)
    if d is None:
        d = 40.0
    return min(range(len(R82XX_GAINS)), key=lambda i: abs(R82XX_GAINS[i] - d))


def _dg_eid_ok(eid):
    if eid is None or isinstance(eid, bool):
        return False
    try:
        return int(eid) != 0 if isinstance(eid, (int, float)) else int(str(eid).strip(), 0) != 0
    except (ValueError, TypeError):
        return False


def dabgain_step(st, sync, now, ch):
    """Leiter: Sync -> Stufe ok; DABGAIN_FAIL_N Pruefungen ohne Sync hintereinander -> naechste Stufe. -> (alt, neu) bei Wechsel."""
    cur = st.get("cur")
    if sync:
        st.update({"ok": cur, "ok_t": int(now), "fail_n": 0, "ok_ch": ch})
        return None
    st["fail_n"] = int(st.get("fail_n") or 0) + 1
    if st["fail_n"] < DABGAIN_FAIL_N:
        return None
    lad = list(DABGAIN_LADDER)
    nx = lad[(lad.index(cur) + 1) % len(lad)] if cur in lad else lad[0]
    st["tried"] = ([y for y in (st.get("tried") or []) if y != cur] + [cur])[-8:]
    st.update({"cur": nx, "fail_n": 0, "t_change": int(now)})
    return cur, nx


def _dg_parse(mux, now=None):
    x = _dg_orig_parse(mux, now)
    if x is None or not isinstance(mux, dict):
        return x
    try:
        ens = mux.get("ensemble") if isinstance(mux.get("ensemble"), dict) else None
        sv = mux.get("services") if isinstance(mux.get("services"), list) else None
        x["ens_id"] = ens.get("id") if ens else None
        x["n_svc"] = len(sv) if sv is not None else None
        ok_e = True
        if ens is not None or sv is not None:
            ok_e = _dg_eid_ok(x["ens_id"]) or bool(x.get("ens")) or bool(sv)
        rc = mux.get("receiver") if isinstance(mux.get("receiver"), dict) else {}
        sw = rc.get("software") if isinstance(rc.get("software"), dict) else {}
        hw = rc.get("hardware") if isinstance(rc.get("hardware"), dict) else {}
        lcc = _dfnum(sw.get("lastchannelchange"))
        fct_ok = not (x.get("fct0") and lcc and abs(float(x["fct0"]) - lcc) < 1.0)
        x["hw_gain"] = _dfnum(hw.get("gain"))
        x["sync"] = bool(x["sync"] and ok_e and fct_ok)
        if not ok_e or not fct_ok:
            x["nosync_why"] = ("Ensemble leer" if not ok_e else "") + (" " if not ok_e and not fct_ok else "") + ("kein Rahmen seit Umschalten" if not fct_ok else "")
    except Exception as ex:
        print("dabGain parse:", ex, flush=True)
    return x


dabfix_parse = _dg_parse


def _dg_state(self):
    """Planner -> Zustand der Gain-Leiter dieses Sticks (in broadcast_state.json dabgain[SN])."""
    sn = str(getattr(self, "dev_sn", None) or cfg_serial(self.cfg) or "?")
    allg = self.sbc.d.get("dabgain") if isinstance(self.sbc.d.get("dabgain"), dict) else {}
    self.sbc.d["dabgain"] = allg
    st = allg.get(sn) if isinstance(allg.get(sn), dict) else {}
    if st.get("cur") not in DABGAIN_LADDER and _dfnum(st.get("cur")) is None:
        d0 = _dfnum(self.cfg.get("gain_dab_db"))
        st = {"cur": R82XX_GAINS[dabgain_index(d0)] if d0 is not None else DABGAIN_LADDER[0], "ok": None, "ok_t": None, "fail_n": 0, "tried": []}
    allg[sn] = st
    return st


def _dg_add_g(self, cmds, kind, ch):
    if self.cfg.get("gain_dab") not in (None, ""):
        return cmds  # Stufe von Hand gesetzt (wie bisher, welle-cli -g) -> nichts aendern
    st = _dg_state(self)
    use = st.get("ok") if kind == "cal" else st.get("cur")
    if kind == "cal" and use is None:
        return cmds
    for a in cmds if isinstance(cmds, list) else []:
        if isinstance(a, list) and "-F" in a and "-g" not in a:
            i = a.index("-F")
            if i + 1 < len(a) and str(a[i + 1]).startswith("rtl_tcp"):
                if use != "agc":
                    a += ["-g", str(dabgain_index(use))]
                self._dg_used = {"ch": str(ch), "kind": kind, "db": use, "idx": None if use == "agc" else dabgain_index(use), "since": None}
    return cmds


def _dg_cmd_dab(self, ch):
    cmds = _dg_orig_cmd_dab(self, ch)
    try:
        self._dg_used = None
        cmds = _dg_add_g(self, cmds, "dab", ch)
    except Exception as ex:
        print("dabGain cmd:", ex, flush=True)
    return cmds


def _dg_cmd_cal(self, i):
    cmds = _dg_orig_cmd_cal(self, i)
    try:
        cmds = _dg_add_g(self, cmds, "cal", self.dab_list()[0])
    except Exception as ex:
        print("dabGain cal:", ex, flush=True)
    return cmds


def _dg_on_dab(self, ch, mux, now=None):
    dd = self.d.get("dab") if isinstance(self.d.get("dab"), dict) else {}
    prev = dict(dd.get(ch) or {}) if isinstance(dd.get(ch), dict) else {}
    r = _dg_orig_on_dab(self, ch, mux, now)
    try:
        if isinstance(r, dict):
            t = int(now or time.time())
            x = dabfix_parse(mux, t) or {}
            dm = r.get("demod") if isinstance(r.get("demod"), dict) else None
            if dm is not None:
                dm.update({"ens_id": x.get("ens_id"), "n_svc": x.get("n_svc"), "hw_gain": x.get("hw_gain")})
                g = getattr(self, "_dg_gain", None)
                if isinstance(g, dict) and str(g.get("ch")) == str(ch):
                    dm["gain_db"], dm["gain_idx"] = g.get("db"), g.get("idx")
            dec = bool(r.get("ensemble")) or bool(r.get("services"))
            if dec:
                r.update({"rx": True, "nosync_n": 0})
                r.pop("rx_why", None)
                r.pop("try_t", None)
            else:
                new = dict(r)
                for k in ("t", "ensemble", "services", "alarm", "n", "asa"):
                    if k in prev:
                        new[k] = prev[k]
                    elif k == "t":
                        new.pop("t", None)
                new.update({"rx": False, "try_t": t, "nosync_n": int(prev.get("nosync_n") or 0) + 1,
                            "rx_why": "kein Sync: %s" % (x.get("nosync_why") or "Ensemble leer, 0 Dienste")})
                if prev.get("t"):
                    new["last_ok_t"] = prev.get("t")
                self.d["dab"][ch] = new
                self.dirty = True
                return new
    except Exception as ex:
        print("dabGain on_dab:", ex, flush=True)
    return r


def _dg_sub_done(self, sp, now):
    job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") and sp.get("i", 0) < len(sp["queue"]) else ""
    pre = None
    try:
        if job.startswith("dab:") and self.procs and self.alive():
            pre = {"ch": str(self.dab_list()[int(job[4:])]), "ran": now - self.since}
            u = getattr(self, "_dg_used", None)
            st = _dg_state(self)
            self.sbc._dg_gain = dict(u) if isinstance(u, dict) else {"ch": pre["ch"], "db": "fest (gain_dab %s)" % self.cfg.get("gain_dab") if self.cfg.get("gain_dab") not in (None, "") else "Einzelstick-Weg", "idx": None}
            self.sbc._dg_gain["ch"] = pre["ch"]
            pre["st"] = st
            pre["managed"] = isinstance(u, dict) and u.get("kind") == "dab"
    except Exception as ex:
        print("dabGain vor sub_done:", ex, flush=True)
    try:
        return _dg_orig_sub_done(self, sp, now)
    finally:
        try:
            self.sbc._dg_gain = None
            if pre and pre.get("managed") and pre["ran"] >= DABGAIN_MIN_S:
                st = pre["st"]
                dm = ((self.sbc.d.get("dab") or {}).get(pre["ch"]) or {}).get("demod") or {}
                if dm.get("t") and now - dm["t"] < 120:
                    ch_ = dabgain_step(st, bool(dm.get("sync")), now, pre["ch"])
                    if ch_:
                        self.log("dabGain: %s ohne Sync mit %s -> naechster Versuch %s" % (pre["ch"], ch_[0], ch_[1]))
                    self.sbc.dirty = True
        except Exception as ex:
            print("dabGain nach sub_done:", ex, flush=True)


Planner._cmd_dab = _dg_cmd_dab
Planner._cmd_cal = _dg_cmd_cal
StateBC.on_dab = _dg_on_dab
Planner.sub_done = _dg_sub_done


def selftest_dabgain():
    assert dabgain_index(40) == 22 and R82XX_GAINS[dabgain_index(40)] == 40.2 and dabgain_index(49.6) == 28 and dabgain_index(None) == 22
    t0 = 1790000000.0
    live = {"receiver": {"software": {"lastchannelchange": 1789999990000}, "hardware": {"gain": 0.0}},
            "ensemble": {"label": {"label": ""}, "id": "0x0000"}, "services": [],
            "demodulator": {"snr": 0.0, "fic": {"numcrcerrors": 0}, "time_last_fct0_frame": 1789999990000}}
    a = dabfix_parse(live, t0 - 7)
    assert a["sync"] is False and a["hw_gain"] == 0.0 and a["n_svc"] == 0, a
    good = {"receiver": {"software": {"lastchannelchange": 1789999990000}, "hardware": {"gain": 40.2}},
            "ensemble": {"label": {"label": "Bayern"}, "id": "0x10a5"}, "services": [{"label": {"label": "BR24"}}],
            "demodulator": {"snr": 12.0, "fic": {"numcrcerrors": 3}, "time_last_fct0_frame": int((t0 - 0.2) * 1000)}}
    assert dabfix_parse(good, t0)["sync"] is True
    assert dabfix_parse(dict(good, ensemble={"label": {"label": ""}, "id": "0x10a5"}, services=[]), t0)["sync"] is True
    assert dabfix_parse(dict(good, ensemble={"label": {"label": ""}, "id": "0x0000"}, services=[]), t0)["sync"] is False
    import tempfile
    tmp = tempfile.mkdtemp()
    bx = StateBC(tmp)
    r = bx.on_dab("11D", good, now=t0)
    assert r["rx"] and r["t"] == int(t0) and r["ensemble"] == "Bayern", r
    r = bx.on_dab("11D", live, now=t0 + 1800)
    assert r["rx"] is False and r["t"] == int(t0) and r["ensemble"] == "Bayern" and r["nosync_n"] == 1 and r["try_t"] == int(t0 + 1800), r
    assert r["demod"]["snr"] is None and r["demod"]["fic_rate"] is None and r["demod"]["hw_gain"] == 0.0 and r["demod"]["ens_id"] == "0x0000", r["demod"]
    r = bx.on_dab("5C", live, now=t0)
    assert "t" not in r and r["rx"] is False and bx.d["dab"]["5C"]["ensemble"] == "", r
    pl = Planner.__new__(Planner)
    pl.cfg = dict(DEFAULT_CFG, serial="19348831", dab_tcp_port=1235)
    pl.sbc, pl.dev_sn = bx, "19348831"
    cm = _dg_add_g(pl, [["rtl_tcp", "-a", "127.0.0.1"], ["welle-cli", "-c", "11D", "-w", "7979", "-F", "rtl_tcp,127.0.0.1:1235"]], "dab", "11D")
    assert cm[1][-2:] == ["-g", "22"] and cm[0] == ["rtl_tcp", "-a", "127.0.0.1"], cm
    cm = _dg_add_g(pl, [["welle-cli", "-c", "11D", "-F", "rtl_sdr"]], "dab", "11D")
    assert "-g" not in cm[0]
    assert "-g" not in _dg_add_g(pl, [["welle-cli", "-F", "rtl_tcp,127.0.0.1:1235"]], "cal", "11D")[0]
    pl.cfg["gain_dab"] = 30
    assert "-g" not in _dg_add_g(pl, [["welle-cli", "-F", "rtl_tcp,127.0.0.1:1235"]], "dab", "11D")[0]
    st = {"cur": 40.2, "ok": None, "fail_n": 0, "tried": []}
    assert dabgain_step(st, False, 1, "11D") is None and dabgain_step(st, False, 2, "5C") == (40.2, 32.8) and st["cur"] == 32.8 and st["tried"] == [40.2]
    assert dabgain_step(st, True, 3, "11D") is None and st["ok"] == 32.8 and st["fail_n"] == 0
    st2 = {"cur": 49.6, "fail_n": 1}
    assert dabgain_step(st2, False, 4, "11D") == (49.6, "agc") and dabgain_step({"cur": 49.6, "fail_n": 1}, False, 5, "x")[1] == "agc"
    st3 = {"cur": "agc", "fail_n": 1}
    assert dabgain_step(st3, False, 6, "x") == ("agc", 40.2)
    print("selftest dabGain ok (Stufe 22 = 40,2 dB am rtl_tcp-Weg, Sync nur mit echtem Ensemble, DAB-Empfang ehrlich, Leiter)", flush=True)
# ===== /dabGain =====
DGSDR_EOF
EXPECT_PATCH="7681f5a3e0dcfd09942179cb492516cfe082d3a6647731c096ba9b93d25e30fa"
cat > "$W/patch-dg.py" << 'DGPATCH_EOF'
"""dabGain: Block in prepper_sdr.py einsetzen oder ersetzen (idempotent).
Aufruf: patch-dg.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== dabGain:", "# ===== /dabGain =====\n"
ANCHOR = "# ===== /dabFix =====\n"
ST0, ST1 = "        selftest_dabfix()\n", "        selftest_dabgain()\n"
NEED = ("class StateBC:", "class Planner:", "class NoiseState:", "    def on_dab(self, ch, mux, now=None):", "    def want(self, mode, now):",
        "    def noise_summary(self):", "    def add(self, r, cfg, now=None):", "DAB_CHANNELS = {", "FM_DEFAULT = [", "LZDB_FIB_PER_S = ",
        "StateBC.on_dab = _lzdb_on_dab\n", "StateBC.on_dab = _dabfix_on_dab\n", "dabfix_parse(mux, now)", "    def _cmd_dab(self, ch):", "    def _cmd_cal(self, i):", "def cfg_serial(", "# ===== dabFix:", "def _med(xs):", "def preset(", "# ===== dabHist:", "# ===== stickTestFix:", "# ===== lageDB:")
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(ST0) != 1:
    bad.append("selftest_dabfix() x%d" % s.count(ST0))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("dabGain-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: dabGain-Block steht nicht direkt nach /dabFix"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
if ST1 not in s2:
    s2 = s2.replace(ST0, ST0 + ST1, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
DGPATCH_EOF
EXPECT_GUARD="383fcb5e8f85fe39d192e27feb101af4d730682d32efa51d791eb623dd1f4b6f"
cat > "$W/guard_dg.py" << 'DGGUARD_EOF'
"""dabGain AST-Guard. Aufruf: guard_dg.py SDR_ALT SDR_NEU -> 0 ok, 1 Verstoss.
Keine Sendestelle, kein shell=True, keine neuen Sockets/Server/Prozesse/Faeden, keine neuen Importe, kein Netzabruf; der Block haengt nur
"-g STUFE" an die vorhandene welle-cli-Kommandozeile (rtl_tcp-Weg) und wertet vorhandene Messwerte aus."""
import ast
import sys

RISKY = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "sendText", "sendData", "TCPInterface", "urlopen", "socket",
         "create_connection", "bind", "listen", "connect", "serve_forever", "HTTPServer", "make_server", "system", "Popen", "run", "call", "check_output",
         "check_call", "execv", "spawn", "fork", "Thread", "Timer", "start_new_thread", "kill", "killpg", "_dev", "write_json", "remove", "unlink")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "os", "signal", "threading"}


def info(src):
    t = ast.parse(src)
    imp, calls, shell, attrs = set(), [], 0, []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False):
            shell += 1
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            calls.append(nm)
            if isinstance(f, ast.Attribute):
                attrs.append(((f.value.id if isinstance(f.value, ast.Name) else "?"), f.attr))
    return imp, calls, shell, attrs


rd = lambda f: open(f, encoding="utf-8").read()
s0, s1 = rd(sys.argv[1]), rd(sys.argv[2])
A, Z = "# ===== dabGain:", "# ===== /dabGain ====="
err = []
if s1.count(A) != 1 or s1.count(Z) != 1:
    err.append("dabGain-Marker nicht genau 1x")
blk = s1[s1.index(A):s1.index(Z) + len(Z) + 1] if A in s1 else ""
old = s0[s0.index(A):s0.index(Z) + len(Z) + 1] if A in s0 else ""
rest0 = s0.replace(old, "") if old else s0
rest1 = s1.replace(blk, "")
if rest1.replace("        selftest_dabgain()\n", "") != rest0.replace("        selftest_dabgain()\n", ""):
    err.append("ausserhalb des dabFix-Blocks geaendert (ausser Aufruf selftest_dabgain)")
bi, bc, bs, _ = info(s0)
ni, nc, ns, _ = info(s1)
if ni != bi:
    err.append("Importe geaendert %s" % (ni ^ bi))
if ns != bs:
    err.append("shell=True geaendert")
_bi, kc, ks, ka = info(blk)
for nm in RISKY:
    if nm in kc:
        err.append("Block ruft %s" % nm)
if _bi - {"tempfile"}:
    err.append("Block importiert %s" % (_bi - {"tempfile"}))
if [x for x in ka if x[0] in NETMOD]:
    err.append("Block: Netz-/Prozessaufruf %s" % [x for x in ka if x[0] in NETMOD])
net = [x for x in ka if x[0] == "prepper_sdr_net"]
if net or "fetch_welle" in kc:
    err.append("Block: Netzabruf %s" % net)
adds = [n for n in __import__("ast").walk(__import__("ast").parse(blk)) if isinstance(n, __import__("ast").AugAssign)]
for n in adds:
    v = n.value
    if isinstance(n.target, __import__("ast").Name) and n.target.id == "a" and not (isinstance(v, __import__("ast").List) and v.elts and isinstance(v.elts[0], __import__("ast").Constant) and v.elts[0].value == "-g"):
        err.append("Block: Kommandozeile anders als -g erweitert")
for w in ("mesh", "transmit", "-T", "rtl_fm", "rtl_power", "Popen", "open(", "subprocess", "socket", "requests", "urllib", "send(", ".send", "sendtext"):
    if w in blk.lower():
        err.append("Block enthaelt %s" % w)
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard dabGain: nur Block + Selbsttest-Aufruf neu, keine neuen Importe, kein shell=True, keine Sende-/Socket-/Prozess-/Faden-/Netz-Aufrufe; "
      "Kommandozeile nur um -g STUFE erweitert")
DGGUARD_EOF
EXPECT_SHOW="5665e12b1ce59168941183be9b6d728ed12f21a9443a8cf5fdad765bc1207e9d"
cat > "$W/show_dg.py" << 'DGSHOW_EOF'
"""dabGain Anzeige (nur lesen).
show_dg.py chans SDR_CONFIG
show_dg.py dab BSTATE T0 CH... [--final]  -> 0 wenn alle Kanaele eine neue Pruefung haben
show_dg.py noise STATUS T0 [--final]
show_dg.py hints BSTATE STATUS DABHIST BR24_JSON"""
import json
import sys


def ld(f):
    try:
        return json.load(open(f, encoding="utf-8"))
    except Exception:
        return {}


def fnum(v, nd=2):
    return "-" if v is None else (("%." + str(nd) + "f") % v if isinstance(v, (int, float)) else str(v))


a = sys.argv[1]
fin = "--final" in sys.argv
args = [x for x in sys.argv[2:] if x != "--final"]
if a == "chans":
    c = ld(args[0])
    v = [str(x) for x in (c.get("dab") if isinstance(c.get("dab"), list) and c.get("dab") else ["11D"])]
    if c.get("asa_5c", True) and "5C" not in v:
        v.append("5C")
    print(" ".join(v))
elif a == "dab":
    d = ld(args[0]).get("dab") or {}
    t0, chs = float(args[1]), args[2:]
    got = {ch: d.get(ch) or {} for ch in chs}
    new = [ch for ch in chs if ((got[ch].get("demod") or {}).get("t") or 0) >= t0]
    if len(new) < len(chs) and not fin:
        sys.exit(2)
    for ch in chs:
        e = got[ch]
        g = e.get("demod") or {}
        if ch not in new:
            print("  DAB %s: noch keine neue Pruefung" % ch)
            continue
        if e.get("rx") is False:
            print("  DAB %s: KEIN SYNC (%s) - Ensemble-Kennung %s, Dienste %s, welle-Gain %s dB, Stufe %s (%s dB), Proben %s, zuletzt echt empfangen %s" % (
                ch, e.get("rx_why"), g.get("ens_id"), g.get("n_svc"), g.get("hw_gain"), g.get("gain_idx"), g.get("gain_db"), g.get("n_samp"), e.get("last_ok_t") or "nie"))
        else:
            print("  DAB %s: Sync ja%s - Ensemble %s (%s), Dienste %s, SNR %s dB (Median %s, %s x 0)%s, FIC-Fehlerrate %s (%s Fehler in %s s), welle-Gain %s dB, Stufe %s (%s dB)" % (
                ch, (" nach %s s" % g.get("sync_s")) if g.get("sync_s") is not None else "", e.get("ensemble") or "?", g.get("ens_id"), len(e.get("services") or []),
                fnum(g.get("snr"), 1), fnum(g.get("snr_med"), 1), g.get("snr0_n"), (" [%s]" % g["snr_why"]) if g.get("snr_why") else "",
                fnum(g.get("fic_rate"), 6), g.get("fic_derr"), g.get("secs"), g.get("hw_gain"), g.get("gain_idx"), g.get("gain_db")))
    sys.exit(0 if len(new) == len(chs) else 2)
elif a == "noise":
    st, t0 = ld(args[0]), float(args[1])
    out, ok = [], False
    for lab, n in (("Stick 1", st.get("noise")), ("Stick 2", (st.get("s2") or {}).get("noise") if isinstance(st.get("s2"), dict) else None)):
        if not isinstance(n, dict):
            continue
        bd = {b.get("id"): b for b in n.get("bands") or []}
        dab, q = bd.get("dab") or {}, n.get("qrm") or {}
        if dab and (dab.get("t") or 0) >= t0 and (q.get("t") or 0) >= (dab.get("t") or 0):
            ok = True
        out.append("  %s: QRM gesamt %s; %s" % (lab, q.get("lvl"), "; ".join("%s %s n_pers %s bekannt %s" % (b.get("short") or b.get("id"), b.get("lvl"), b.get("n_pers"), b.get("n_bc"))
                                                                           for b in bd.values() if b)))
        for b in bd.values():
            for c in (b.get("cars") or [])[:2]:
                out.append("     Stoerer %s: %s MHz %s dB %s kHz" % (b.get("short") or b.get("id"), c.get("f"), c.get("db"), c.get("w_khz")))
    if not ok and not fin:
        sys.exit(2)
    print("\n".join(out) if out else "  (keine Stoerer-Messung im Status)")
    sys.exit(0 if ok else 2)
elif a == "hints":
    b, st, dh, br = ld(args[0]), ld(args[1]), ld(args[2]), ld(args[3])
    print("  Gain-Leiter je Stick (dabgain): %s" % json.dumps(b.get("dabgain"), ensure_ascii=False)[:400])
    for lab, x in (("Stick 1", st), ("Stick 2", st.get("s2") if isinstance(st.get("s2"), dict) else {})):
        print("  %s SN %s Rolle %s: letzte Meldungen welle/rtl_tcp: %s" % (lab, x.get("sn") or x.get("serial"), x.get("role"), " | ".join(str(y)[:120] for y in (x.get("stderr") or [])[-3:]) or "-"))
    ev = dh.get("ev") if isinstance(dh.get("ev"), list) else []
    for ch in ("11D", "5C"):
        xs = [e for e in ev if e.get("ch") == ch]
        print("  /dabhist %s: %d Eintraege, zuletzt %s" % (ch, len(xs), max([e.get("last") or e.get("t") or 0 for e in xs]) if xs else "nie"))
    print("  BR24-Status: %s (Quellen %s, zuletzt %s)" % (br.get("text") or (br.get("br24_row") or {}).get("l1"), br.get("srcs"), br.get("last_src")))
    for k in ("asa_row", "br24_row"):
        if isinstance(br.get(k), dict):
            print("  %s: %s / %s" % (k, br[k].get("l1"), br[k].get("l2")))
elif a == "live":
    d = ld(args[0])
    print("  /api/sdr/live: status %s, ber %s, Mast %s, SDR1 %s, SDR2 %s (%s)" % (d.get("status"), d.get("ber"), d.get("active_mast"), d.get("sdr1_role"), d.get("sdr2_role"), d.get("sdr2_status")))
    seen = set()
    for x in sorted(d.get("telemetry") or [], key=lambda y: -(y.get("ts") or 0)):
        if x.get("channel") in seen:
            continue
        seen.add(x.get("channel"))
        print("    Telemetrie %s: ts %s, SNR %s, ber %s, FIC-Fehler %s in %s s, Stick %s" % (x.get("channel"), x.get("ts"), x.get("snr"), x.get("ber"), x.get("fic_err"), x.get("secs"), x.get("serial")))
DGSHOW_EOF
EXPECT_CFG="0ab54e2df650897d0115db985f76d78db8f714d0bf39c47ee20997b7c37082de"
cat > "$W/cfg_dg.py" << 'DGCFG_EOF'
"""dabGain: noise_fm_known (bestaetigte Ortssender) in sdr_config.json ergaenzen. Aufruf: cfg_dg.py QUELLE ZIEL -> 'gleich'/'geaendert'.
Nur dieser Schluessel; vorhandene Werte bleiben, nichts anderes wird angefasst (Schreiben wie prepper-sdr: JSON, indent 1)."""
import json
import sys
ADD = [96.25, 100.15, 107.2]
src, dst = sys.argv[1:3]
raw = open(src, encoding="utf-8").read()
c = json.loads(raw)
if not isinstance(c, dict):
    raise SystemExit("sdr_config.json ist kein Objekt")
v = c.get("noise_fm_known")
v = [x for x in v if isinstance(x, (int, float)) and not isinstance(x, bool)] if isinstance(v, list) else []
new = v + [x for x in ADD if not any(abs(x - y) < 0.01 for y in v)]
if isinstance(c.get("noise_fm_known"), list) and new == c["noise_fm_known"]:
    open(dst, "w", encoding="utf-8").write(raw)
    print("gleich")
else:
    c["noise_fm_known"] = new
    open(dst, "w", encoding="utf-8").write(json.dumps(c, ensure_ascii=False, indent=1))
    print("geaendert")
DGCFG_EOF
P="$W/patch-dg.py"; BK="$W/dg_sdr_block.py"; SG="$W/guard_dg.py"; SH="$W/show_dg.py"; CF="$W/cfg_dg.py"
for x in "$EXPECT_BLK $BK" "$EXPECT_PATCH $P" "$EXPECT_GUARD $SG" "$EXPECT_SHOW $SH" "$EXPECT_CFG $CF"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis (an Guards erkannt) ----------
[[ -f "$F" && -f "$M" && -f "$C" ]] || { echo "STOP: dashboard.py/prepper_sdr.py/sdr_config.json fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
case " $KNOWN_SDR16 " in *" $S16 "*) KN=bekannt;; *) KN="neu, Erkennung ueber Guards";; esac
case " $KNOWN_DASH16 " in *" $D16 "*) KD=bekannt;; *) KD="neu, Erkennung ueber Guards";; esac
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $KN); dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $KD, bleibt unveraendert)"
grep -q "# ===== lageDB:" "$F" || { echo "STOP: Dashboard ohne lageDB-Guard (sha16 $D16) - erst apply-lagedb.sh, nichts geaendert"; exit 1; }
python3 "$P" "$M" "$W/work/prepper_sdr.py" "$BK" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
python3 "$CF" "$C" "$W/work/sdr_config.json" > "$W/c1.log" || { cat "$W/c1.log"; echo "STOP: sdr_config.json nicht lesbar - nichts geaendert"; exit 1; }
python3 "$CF" "$W/work/sdr_config.json" "$W/work/c2.json" | grep -q gleich || { echo "STOP: sdr_config-Ergaenzung nicht idempotent"; exit 1; }
rm -f "$W/work/c2.json"
echo "OK Basis erkannt: Guards dabFix + lageDB + dabHist + stickTestFix in prepper_sdr, Anker /dabFix genau 1x, lageDB-Guard im Dashboard; prepper_sdr $(cat "$W/p1.log"), sdr_config.json noise_fm_known $(cat "$W/c1.log")"
SDR_ACT=$(systemctl is-active prepper-sdr 2>/dev/null || true)
[[ "$SDR_ACT" == active ]] || { echo "STOP: prepper-sdr ist nicht aktiv ($SDR_ACT) - erst Dienst pruefen, nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$P" "$W/work/prepper_sdr.py" "$W/work/s2.py" "$BK" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
rm -f "$W/work/s2.py"
for py in "$SPY" "$VPY"; do "$py" -W error -m py_compile "$W/work/prepper_sdr.py" || { echo "STOP: py_compile prepper_sdr ($py) - nichts geaendert"; exit 1; }; done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
cp "$W/work/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest dabHist ok" "selftest OK:"; do grep -q "$k" "$W/selftest.log" || { echo "STOP: Selbsttest ohne $k ($py)"; exit 1; }; done
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox): $(grep 'selftest dabGain ok' "$W/selftest.log")"
python3 "$SG" "$M" "$W/work/prepper_sdr.py" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys,time
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
# ---------- 3) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_config.json" "$C"; then
  echo "OK dabGain schon installiert - kein Neustart"
  T0=$(python3 -c "import json;print(int(json.load(open('$DASH_DIR/sdr_status.json')).get('started') or 0))" 2>/dev/null || echo 0)
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    for x in "$M" "$C"; do [[ -f "$x.bak-dabgain-$TS" ]] && cp -a "$x.bak-dabgain-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    for x in "$M" "$C"; do cmp -s "$x" "$x.bak-dabgain-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    sleep 5
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "$M" "$C" "$DASH_DIR/noise_state.json" "$DASH_DIR/broadcast_state.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-dabgain-$TS"
    { ls -1t "$x.bak-dabgain-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-dabgain-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  if ! cmp -s "$W/work/sdr_config.json" "$C"; then
    cp "$W/work/sdr_config.json" "$C.new" && chmod --reference="$C.bak-dabgain-$TS" "$C.new" && chown --reference="$C.bak-dabgain-$TS" "$C.new" 2>/dev/null; mv -f "$C.new" "$C" || { rb "installieren sdr_config.json"; exit 1; }
  fi
  sudo systemctl restart prepper-sdr.service
  echo "Neustart: nur prepper-sdr - warte auf frischen SDR-Status (max 120 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 60); do sleep 2; systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr schreibt keinen frischen Status"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /api/sdr/ui /api/sdr/live; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
sleep 8
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
sdr_fresh "$T0" || rbx "SDR-Status nicht frisch"
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
n=d.get('noise') or {}
assert isinstance(n.get('bands'), list), 'noise.bands fehlt'
print('  OK sdr_status.json: aktiv %s, Rolle %s, QRM %s' % (d.get('active'), d.get('role'), (n.get('qrm') or {}).get('lvl')))" "$DASH_DIR/sdr_status.json" || rbx "sdr_status.json unvollstaendig"
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live0.json" || true
python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); assert d.get('status') in ('SDR_OFFLINE','OK','PROBEALARM','ECHTALARM'), d.get('status')" "$W/live0.json" || rbx "/api/sdr/live ungueltig"
python3 "$SH" live "$W/live0.json"
c=$(code -X POST "$B/api/sdr/live"); [[ "$c" == 405 ]] && echo "OK POST /api/sdr/live abgelehnt (405)" || rbx "POST /api/sdr/live nicht abgelehnt ($c)"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "dabFix (Probe|on_dab|Stoerer-Filter|Status):|dabGain [a-z ]+:|Traceback" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne dabFix/dabGain-Fehler/Traceback" || echo "WARNUNG: $E dabFix/dabGain-Fehler/Traceback-Zeilen im Journal (Wert bleibt dann wie vor dabFix)"
python3 -c "import json,sys;print('  sdr_config.json noise_fm_known =', json.load(open(sys.argv[1])).get('noise_fm_known'))" "$C"
echo "OK guards dabGain=$(grep -c '# ===== dabGain:' "$M" || true) dabFix=$(grep -c '# ===== dabFix:' "$M" || true) lageDB(sdr)=$(grep -c '# ===== lageDB:' "$M" || true) dabHist(sdr)=$(grep -c '# ===== dabHist:' "$M" || true) stickTestFix(sdr)=$(grep -c '# ===== stickTestFix:' "$M" || true) lageDB(dash)=$(grep -c '# ===== lageDB:' "$F" || true) lageGeo(dash)=$(grep -c '# ===== lageGeo:' "$F" || true)"
[[ -f "$M.bak-dabgain-$TS" ]] && echo "Backups: *.bak-dabgain-$TS (prepper_sdr.py, sdr_config.json, noise_state.json, broadcast_state.json), behalten: letzte $KEEP_LAST"
echo "prepper_sdr.py sha16 jetzt $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen; dashboard.py sha16 $(sha256sum "$F" | cut -c1-16) (unveraendert), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG dabGain=1 - Einspielen fertig. Jetzt nur noch Anzeige: Warten ist ungefaehrlich, Abbruch mit Strg-C aendert nichts."
# ---------- 5) Warten auf DAB-Pruefung + Stoerer-Messung (nur Anzeige) ----------
CH=$(python3 "$SH" chans "$DASH_DIR/sdr_config.json")
echo "Warte auf naechste DAB-Pruefung ($CH) und Stoerer-Messung DAB, max $DAB_WAIT_S s (Rundfunk-Block ca. 2 min nach Neustart, Messung ca. 5 min) ..."
dd=0; nn=0; t=0
while [[ "$t" -lt "$DAB_WAIT_S" ]]; do
  if [[ "$dd" == 0 ]] && python3 "$SH" dab "$DASH_DIR/broadcast_state.json" "$T0" $CH > "$W/dab.txt"; then dd=1; echo "DAB-Pruefung nach $t s:"; cat "$W/dab.txt"; fi
  if [[ "$nn" == 0 ]] && python3 "$SH" noise "$DASH_DIR/sdr_status.json" "$T0" > "$W/nz.txt"; then nn=1; echo "Stoerer-Messung nach $t s:"; cat "$W/nz.txt"; fi
  [[ "$dd" == 1 && "$nn" == 1 ]] && break
  systemctl is-active --quiet prepper-sdr || { echo "WARNUNG: prepper-sdr laeuft nicht mehr - bitte melden"; break; }
  sleep 15; t=$((t + 15))
  [[ $((t % 120)) == 0 ]] && echo "  ... $t s (DAB $([[ $dd == 1 ]] && echo da || echo offen), Messung $([[ $nn == 1 ]] && echo da || echo offen))"
done
[[ "$dd" == 1 ]] || { echo "DAB: nach $DAB_WAIT_S s noch nicht alle Kanaele neu, Stand:"; python3 "$SH" dab "$DASH_DIR/broadcast_state.json" "$T0" $CH --final || true; }
[[ "$nn" == 1 ]] || { echo "Stoerer-Messung: noch nicht neu, Stand:"; python3 "$SH" noise "$DASH_DIR/sdr_status.json" "$T0" --final || true; }
sleep 3
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
python3 "$SH" live "$W/live.json" || true
sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "dabFix DAB|dabGain" | tail -6 | cut -c1-220 || true
"${CURL[@]}" "$B/api/br24" -o "$W/br24.json" || true
if grep -q "KEIN SYNC" "$W/dab.txt" 2>/dev/null || [[ "$dd" == 0 ]]; then
  echo "HINWEIS (kein Rollback): mindestens ein DAB-Kanal ohne Sync. Die Gain-Leiter probiert je 2 Pruefungen ohne Sync die naechste Stufe (40,2 / 32,8 / 44,5 / 28,0 / 49,6 dB / AGC)."
  echo "  Bleibt es bei allen Stufen ohne Sync: Antenne/Kabel an Stick 1 pruefen (Stick-Test), Stick 2 kalibriert ueber denselben rtl_tcp-Weg."
fi
echo "Diagnose (nur lesen):"
python3 "$SH" hints "$DASH_DIR/broadcast_state.json" "$DASH_DIR/sdr_status.json" "$DASH_DIR/sdr_dabhist.json" "$W/br24.json" || true
echo "COMMIT $COMMIT_ARG dabGain=1 fertig"
