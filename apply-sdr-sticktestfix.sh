#!/bin/bash
set -euo pipefail
# stickTestFix: Antennentest robust - vor jedem Schritt Stick nachweislich frei (Planer-Prozesse beendet, kein SDR-Programm offen, rtl_eeprom-Oeffnungspruefung,
# Wiederholung), stderr vollstaendig, rtl_power Einzeldurchlauf (-1), APRS-Audiopegel (direwolf -a 10), Dauer einstellbar (Standard 120 s 433/APRS).
# /funk: Kachel Antennentest serverseitig als letzte Kachel IM Raster, Zeilen umbrechen. Rollen nie automatisch. Kein Neu-Lernen in diesem Lauf.
# Neustart nur prepper-sdr und prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sticktestfix-apply
KEEP_LAST=3
BASE_DASH16="6463ee1d7c536629"  # live mit stickTest (17285 Zeilen)
BASE_MOD16="1449cc9ebbf6e4be"  # live mit stickTest (4580 Zeilen)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== stickTestFix apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_BLK="fb486645b1eaf2565103bb281fd5085b23596eb6aab72bd14762e5db92c12ec1"
cat > "$W/dfix_block.py" << 'FXBLK_EOF'
# ===== stickTestFix: Kachel Antennentest serverseitig als letzte Kachel IN das Kachel-Raster von /funk (volle Breite), lange Zeilen umbrechen, nichts ausserhalb =====
import re as _stkf_re

_STKF_DIV = _stkf_re.compile(r"<div\b[^>]*>|</div\s*>", _stkf_re.I)
_STKF_GRID = _stkf_re.compile(r"<div\b[^>]*\bclass=[\"'](?:[^\"']*\s)?grid(?:\s[^\"']*)?[\"'][^>]*>", _stkf_re.I)
_STKF_CARD = _stkf_re.compile(r"<div\b[^>]*\bclass=[\"'](?:[^\"']*\s)?card(?:\s[^\"']*)?[\"']", _stkf_re.I)


def _stkf_close(body, start):
    """Index des passenden </div> zum <div> bei start, sonst -1."""
    d = 0
    for m in _STKF_DIV.finditer(body, start):
        if m.group(0).startswith("</"):
            d -= 1
            if d == 0:
                return m.start()
        else:
            d += 1
    return -1


def _stkf_grid(body):
    """(start, ende) des Haupt-Rasters (das Raster mit den meisten Kacheln), sonst None."""
    best = None
    for m in _STKF_GRID.finditer(body):
        e = _stkf_close(body, m.start())
        if e < 0:
            continue
        n = len(_STKF_CARD.findall(body, m.end(), e))
        if best is None or n > best[0]:
            best = (n, m.start(), e)
    return (best[1], best[2]) if best else None


def _stkf_insert(body, card):
    g = _stkf_grid(body)
    if not g:
        return None
    return body[:g[1]] + card + body[g[1]:]


_STK_JS = _STK_JS.replace(
    """function bottom(){var c=document.getElementById('stickTestCard');if(!c)return null;var cs=document.querySelectorAll('.card:not(#stickTestCard)');var lc=cs.length?cs[cs.length-1]:null;var par=lc?lc.parentNode:null;
if(par&&(c.parentNode!==par||par.lastElementChild!==c)){var n=par.lastElementChild;if(n!==c){par.appendChild(c);}}return c;}""",
    """function bottom(){var c=document.getElementById('stickTestCard');if(!c)return null;var g=c.parentNode;if(!g||!g.classList||!g.classList.contains('grid'))return c;
var l=g.lastElementChild;while(l&&(l.tagName==='SCRIPT'||l.tagName==='STYLE'))l=l.previousElementSibling;if(l!==c)g.appendChild(c);return c;}""", 1)
_STKF_CSS = """<style id="stkf-css">#stickTestCard{grid-column:1/-1;min-width:0;max-width:100%;box-sizing:border-box;overflow-wrap:anywhere}
#stickTestCard .stk-row{white-space:normal!important;overflow:visible!important;align-items:flex-start!important;line-height:1.45!important;padding:1px 0}
#stickTestCard .stk-row .su-dot{margin-top:5px}
#stickTestCard .stk-tx{min-width:0;overflow:visible!important;text-overflow:clip!important;white-space:normal;overflow-wrap:anywhere;word-break:break-word}
#stickTestCard .stk-bar{min-width:0}#stickTestCard .stk-bar button{max-width:100%;white-space:normal}</style>"""


def _stkf_after(resp):
    try:
        from flask import request as rq
        if rq.path != "/funk" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="stk-css"' in body:
            return resp
        j = body.rfind("</body>")
        if j < 0:
            return resp
        b2 = _stkf_insert(body, _stk_card())
        if b2 is None:
            print("stickTestFix: kein Kachel-Raster auf /funk gefunden - Kachel weggelassen", flush=True)
            return resp
        j = b2.rfind("</body>")
        resp.set_data(b2[:j] + _STK_CSS + _STKF_CSS + _STK_JS + b2[j:])
    except Exception as e:
        print("stickTestFix Seite:", e, flush=True)
    return resp


def _stkf_selftest():
    b = '<html><body><div class="card" id="x">a</div><div class="grid"><div class="card">1</div><div class="card full"><div class="card">n</div></div></div><div class="grid"></div></body></html>'
    o = _stkf_insert(b, '<div class="card full" id="stickTestCard">T</div>')
    assert o.index('id="stickTestCard"') < o.index('</div><div class="grid"></div>') and o.index('id="stickTestCard"') > o.index(">n<"), o
    assert _stkf_insert("<body></body>", "x") is None
    assert "function bottom(){var c=document.getElementById('stickTestCard');if(!c)return null;var g=c.parentNode;" in _STK_JS
    return "stickTestFix selftest ok"


try:
    _stkf_st = _stkf_selftest()
    if "app" in globals():
        _stkf_l = app.after_request_funcs.setdefault(None, [])
        for _stkf_i, _stkf_f in enumerate(list(_stkf_l)):
            if getattr(_stkf_f, "__name__", "") == "_stk_after":
                _stkf_l[_stkf_i] = _stkf_after  # gleiche Stelle, ersetzt (kein zusaetzlicher Haken)
    print("stickTestFix aktiv: Kachel Antennentest im Raster von /funk; %s" % _stkf_st, flush=True)
except Exception as _stkf_e:
    print("stickTestFix:", _stkf_e, flush=True)
# ===== /stickTestFix =====
FXBLK_EOF
EXPECT_PATCH="25032d82fc2cb22a2ee9e441943fa717a8cb3de804bf634e7eb77df1836c8c77"
cat > "$W/patch-dfix.py" << 'FXPATCH_EOF'
"""stickTestFix Dashboard-Teil. Aufruf: patch-dfix.py QUELLE ZIEL BLOCKDATEI -> 0 ok, 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
if "# ===== stickTestFix:" in s:
    open(dst, "w", encoding="utf-8").write(s); print("schon da"); raise SystemExit(0)
a = "# ===== /stickTest =====\n"
for need in (a, "def _stk_after(resp):", "function bottom(){var c=document.getElementById('stickTestCard');if(!c)return null;var cs=", "def _stk_card(now=None):"):
    if s.count(need) != 1:
        print("Basis passt nicht:", need[:50], s.count(need)); raise SystemExit(3)
s = s.replace(a, a + blk)
open(dst, "w", encoding="utf-8").write(s)
print("geaendert")
FXPATCH_EOF
EXPECT_MOD="c782ff3346bdb926d714146bfb2285398d535bb33b696f867e1aaf2e1e074744"
cat > "$W/fix_mod.py" << 'FXMOD_EOF'
# ===== stickTestFix: Stick vor jedem Schritt nachweislich frei (eigene Prozesse beendet, kein SDR-Programm offen, kurze Oeffnungspruefung), stderr vollstaendig, rtl_power Einzeldurchlauf, APRS-Audiopegel ueber direwolf -a, Dauer einstellbar (Standard 120 s) =====
STK_TOOLS = ("rtl_433", "rtl_fm", "rtl_power", "rtl_tcp", "rtl_sdr", "rtl_test", "welle-cli", "redsea", "direwolf", "satdump", "dump1090", "rtl_eeprom")
_STK_AUDIO = re.compile(r"audio level(?:\s+CH\d+)?\s*=?\s*(\d+)")
_STK_ERRPAT = re.compile(r"error|fail|usb_|no supported|no matching|unable|cannot|denied|busy|not found|kein", re.I)


def stk_durations(cfg):
    """sticktest_433_s / sticktest_aprs_s (Standard 120 s), sticktest_pwr_s (Standard 10 s) aus sdr_config.json."""
    global STK_433_S, STK_APRS_S, STK_PWR_S

    def g(k, d, lo, hi):
        try:
            return max(lo, min(hi, int(float(cfg.get(k) or d))))
        except (TypeError, ValueError):
            return d
    STK_433_S, STK_APRS_S, STK_PWR_S = g("sticktest_433_s", 120, 20, 900), g("sticktest_aprs_s", 120, 20, 900), g("sticktest_pwr_s", 10, 2, 60)
    return STK_433_S, STK_APRS_S, STK_PWR_S


def stk_total_s(n_sticks=2):
    return n_sticks * (STK_433_S + STK_APRS_S + 2 * (STK_PWR_S + 12) + 40) + 30


def stk_errtxt(lines):
    """Aussagekraeftigste stderr-Zeile + Klartext."""
    ls = [x for x in (lines or []) if x.strip()]
    if not ls:
        return "keine Meldung"
    hit = [x for x in ls if _STK_ERRPAT.search(x)]
    t = (hit or ls)[-1]
    lo = t.lower()
    if "usb_claim_interface" in lo or "busy" in lo:
        return "Stick belegt (anderes Programm hat ihn offen): " + t
    if "no supported" in lo or "no matching" in lo:
        return "Stick nicht gefunden: " + t
    if "signal caught" in lo and not hit:
        return "vom Test beendet, ohne Messwerte (" + t + ")"
    return t


def stk_proc_scan():
    """Laufende SDR-Programme: [(pid, name, eigenes_kind)]."""
    me = os.getpid()
    out = []
    try:
        pids = [int(x) for x in os.listdir("/proc") if x.isdigit()]
    except Exception:
        return out
    for pid in pids:
        if pid == me:
            continue
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                a0 = f.read().split(b"\0")[0].decode("utf-8", "replace")
        except Exception:
            continue
        nm = os.path.basename(a0)
        if nm not in STK_TOOLS:
            continue
        own, q = False, pid
        for _ in range(12):
            try:
                with open("/proc/%d/stat" % q) as f:
                    q = int(f.read().rsplit(")", 1)[1].split()[1])
            except Exception:
                break
            if q == me:
                own = True
                break
            if q <= 1:
                break
        out.append((pid, nm, own))
    return out


def stk_open_check(idx, timeout=10):
    """Kurze Oeffnungspruefung (nur lesen): rtl_eeprom -d IDX liest die Konfiguration und beendet sich. -> (ok, text)"""
    try:
        pr = subprocess.Popen(["rtl_eeprom", "-d", str(int(idx))], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except FileNotFoundError:
        return True, "rtl_eeprom fehlt - Oeffnungspruefung uebersprungen"
    try:
        o, e = pr.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(pr.pid, signal.SIGKILL)
        except Exception:
            pass
        pr.communicate()
        return False, "rtl_eeprom haengt"
    t = (o + e).decode("utf-8", "replace")
    lo = t.lower()
    if "usb_claim_interface" in lo or "error opening" in lo or "failed to open" in lo or "no supported" in lo or "no matching" in lo:
        return False, stk_errtxt(t.splitlines())
    return True, "frei"


def stk_free(pl, idx, log):
    """Vor jedem Schritt: Planer-Prozesse beider Sticks beendet, keine SDR-Programme mehr offen, Stick laesst sich oeffnen (bis 5 Versuche)."""
    for x in (pl, pl.worker):
        if x is not None and x.procs:
            x.kill()
    end = time.time() + 20
    while True:
        ps = stk_proc_scan()
        if not ps:
            break
        own = [x for x in ps if x[2]]
        for pid, nm, _ in own:
            try:
                os.kill(pid, signal.SIGTERM if time.time() < end - 10 else signal.SIGKILL)
            except Exception:
                pass
        if time.time() > end:
            if own:
                return False, "eigene SDR-Programme lassen sich nicht beenden: " + ", ".join("%s (PID %d)" % (n, p) for p, n, _ in own)
            break  # fremde Programme: Oeffnungspruefung entscheidet
        time.sleep(1)
    foreign = [x for x in stk_proc_scan() if not x[2]]
    why = ""
    for i in range(5):
        ok, why = stk_open_check(idx)
        if ok:
            return True, why
        time.sleep(2 + i)
    if foreign:
        why += " · offen: " + ", ".join("%s (PID %d)" % (n, p) for p, n, _ in foreign)
    return False, why


def stk_run_cmds(cmds, secs, on_line, cwd, log, natural=False):
    """Kette starten, bis secs lesen (natural: Ende des Programms ist normal), sauber beenden, stderr vollstaendig einsammeln.
    -> (frueh_beendet, stderr-Zeilen)"""
    procs, err, prev, ths = [], [], None, []
    early = False
    try:
        for i, a in enumerate(cmds):
            pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  start_new_session=True, cwd=cwd)
            if prev is not None:
                prev.stdout.close()
            procs.append(pr)

            def drain(s, nm=os.path.basename(a[0])):
                try:
                    for raw in iter(s.readline, b""):
                        t = raw.decode("utf-8", "replace").strip()
                        if t:
                            err.append("%s: %s" % (nm, t[:160]))
                            del err[:-40]
                except Exception:
                    pass
            th = threading.Thread(target=drain, args=(pr.stderr,), daemon=True)
            th.start()
            ths.append(th)
            prev = pr

        def rd(s):
            try:
                for raw in iter(s.readline, b""):
                    try:
                        on_line(raw.decode("utf-8", "replace"))
                    except Exception:
                        pass
            except Exception:
                pass
        th = threading.Thread(target=rd, args=(procs[-1].stdout,), daemon=True)
        th.start()
        ths.append(th)
        end = time.time() + secs
        while time.time() < end:
            if any(pr.poll() is not None for pr in procs):
                early = not (natural and all(pr.poll() is not None for pr in procs) and procs[-1].returncode == 0)
                if natural and not early:
                    break
                early = True
                break
            time.sleep(0.5)
    except Exception as e:
        err.append("Start: %s" % e)
        early = True
    finally:
        for pr in procs:
            if pr.poll() is None:
                try:
                    os.killpg(pr.pid, signal.SIGTERM)
                except Exception:
                    pass
        t2 = time.time() + 5
        for pr in procs:
            try:
                pr.wait(timeout=max(0.1, t2 - time.time()))
            except Exception:
                try:
                    os.killpg(pr.pid, signal.SIGKILL)
                    pr.wait(timeout=2)
                except Exception:
                    pass
        for th in ths:
            th.join(timeout=3)  # letzte stderr-/Ausgabezeilen noch lesen
        time.sleep(1.0)
    return early, list(err)


def stk_test_stick(pl, no, sn, ppm, role, prog):
    """Ein Stick nacheinander: 433 (rtl_433 per :SN), APRS (rtl_fm|direwolf, Pegel ueber -a), rtl_power Einzeldurchlauf auf beiden Frequenzen.
    Vor jedem Schritt: Stick nachweislich frei."""
    c = pl.cfg
    r = {"no": no, "sn": sn, "role": role, "present": False, "errs": []}
    lst, e = list_sticks()
    if lst is None:
        r["err"] = "Stick-Liste: %s" % e
        return r
    idx, e = pick_stick(lst, sn)
    if e or idx is None:
        r["err"] = e or "nicht gefunden"
        return r
    r["present"], r["idx"] = True, idx
    pp = ["-p", str(ppm)] if ppm else []

    def free(step):
        ok, why = stk_free(pl, idx, pl.log)
        if not ok:
            r["errs"].append("%s: Stick nicht frei (%s)" % (step, why))
        return ok
    # 433 (bei sofortigem Ende einmal wiederholen)
    acc = {"n": 0, "ids": set(), "rssi": [], "snr": []}
    r["433"] = {"n": None, "ids": None, "rssi": None, "snr": None, "secs": STK_433_S}
    for attempt in (1, 2):
        prog("Stick %d SN %s: 433,92 MHz (%d s)%s" % (no, sn, STK_433_S, " - 2. Versuch" if attempt == 2 else ""))
        if not free("433"):
            break
        t0 = time.time()
        early, er = stk_run_cmds([["rtl_433", "-f", str(c["f433"]), "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"] + pp + ["-d", ":" + sn]],
                                 STK_433_S, lambda ln: stk_parse_433(ln, acc), pl.base, pl.log)
        if early and acc["n"] == 0:
            msg = "433: rtl_433 nach %d s beendet - %s" % (time.time() - t0, stk_errtxt(er))
            if attempt == 1 and time.time() - t0 < 30:
                pl.log("Stick-Test:", msg, "- wiederhole")
                r["errs"].append(msg + " (wiederholt)")
                continue
            r["errs"].append(msg)
        r["433"] = {"n": acc["n"], "ids": len(acc["ids"]), "rssi": stk_avg(acc["rssi"]), "snr": stk_avg(acc["snr"]), "secs": STK_433_S}
        break
    # APRS (gleiche Kette wie im Betrieb, aber Pegelstatistik -a 10 und Heard-Zeilen an)
    prog("Stick %d SN %s: APRS 144,800 MHz (%d s)" % (no, sn, STK_APRS_S))
    conf = p("sdr_direwolf.conf", pl.base)
    try:
        if open(conf).read() != DIREWOLF_CONF:
            raise ValueError
    except Exception:
        with open(conf, "w") as f:
            f.write(DIREWOLF_CONF)
    acc = {"n": 0, "ids": set(), "audio": []}
    r["aprs"] = {"n": None, "ids": None, "audio": None, "secs": STK_APRS_S}
    if free("APRS"):
        a = ["rtl_fm", "-f", str(c["faprs"]), "-s", "24000"] + pp
        if c.get("gain_aprs") not in (None, ""):
            a += ["-g", str(c["gain_aprs"])]
        early, er = stk_run_cmds([a + ["-d", str(int(idx)), "-"], ["direwolf", "-c", conf, "-r", "24000", "-D", "1", "-t", "0", "-a", "10", "-q", "d", "-"]],
                                 STK_APRS_S, lambda ln: stk_parse_aprs(ln, acc), pl.base, pl.log)
        if early and acc["n"] == 0:
            r["errs"].append("APRS: Kette beendet - %s" % stk_errtxt(er))
        if not acc["audio"]:
            r["errs"].append("APRS: kein Audiopegel gemeldet (%s)" % stk_errtxt(er))
        r["aprs"] = {"n": acc["n"], "ids": len(acc["ids"]), "audio": stk_avg(acc["audio"]), "audio_n": len(acc["audio"]), "secs": STK_APRS_S}
    # Rauschboden/Spitze: ein vollstaendiger Durchlauf (-1), Integration STK_PWR_S
    for key, f0 in (("pwr433", to_mhz(c["f433"]) * 1e6), ("pwraprs", to_mhz(c["faprs"]) * 1e6)):
        prog("Stick %d SN %s: Rauschboden %.3f MHz (%d s)" % (no, sn, f0 / 1e6, STK_PWR_S))
        r[key] = {"floor": None, "peak": None, "n": 0}
        if not free(key):
            continue
        acc = {"all": [], "near": []}
        rng = "%.3fM:%.3fM:10k" % ((f0 - 500e3) / 1e6, (f0 + 500e3) / 1e6)
        early, er = stk_run_cmds([["rtl_power", "-f", rng, "-i", str(STK_PWR_S), "-1", "-g", noise_gain(c)] + pp + ["-d", str(int(idx)), "-"]],
                                 STK_PWR_S + 45, lambda ln, f0=f0: stk_parse_power(ln, f0, acc), pl.base, pl.log, natural=True)
        fl = stk_med(acc["all"])
        r[key] = {"floor": None if fl is None else round(fl, 1), "peak": round(max(acc["near"]), 1) if acc["near"] else None, "n": len(acc["all"])}
        if fl is None:
            r["errs"].append("%s: keine Messwerte - %s" % (key, stk_errtxt(er)))
    return r


_stk_run_base = stk_run


def stk_run(pl, req):
    raw = load_json(p("sdr_config.json", pl.base), {}) or {}
    stk_durations(dict(pl.cfg, **{k: v for k, v in raw.items() if str(k).startswith("sticktest_")}))
    pl.log("Stick-Test: Dauer 433 %d s, APRS %d s, Rauschboden %d s je Stick" % (STK_433_S, STK_APRS_S, STK_PWR_S))
    return _stk_run_base(pl, req)


_stk_pause_base = stk_pause


def stk_pause(pl, on, why=""):
    _stk_pause_base(pl, on, why)
    if on and pl.worker is not None and pl.worker.procs:
        pl.worker.kill()  # Stick 2 haengt noch in einem Schritt - hart freimachen
        pl.worker.special = None


def selftest_sticktestfix():
    acc = {"n": 0, "ids": set(), "audio": []}
    for ln in ("ADEVICE0: Sample rate approx. 24.0 k, 0 errors, receive audio level CH0 41", "DB0NU audio level = 34(10/9)   [NONE]   ||||", "[0.4] DB0NU>APNU19,WIDE2-1:!4927.37N/01105.36E#PHG5130 Digi"):
        stk_parse_aprs(ln, acc)
    assert acc["audio"] == [41, 34] and acc["n"] == 1, acc
    assert stk_errtxt(["rtl_433: Allocating 15 zero-copy buffers", "rtl_433: usb_claim_interface error -6"]).startswith("Stick belegt")
    assert stk_errtxt(["rtl_power: Signal caught, finishing scan pass."]).startswith("vom Test beendet")
    assert stk_durations({}) == (120, 120, 10) and stk_durations({"sticktest_433_s": 60, "sticktest_aprs_s": "5"}) == (60, 20, 10)
    stk_durations({})
    assert stk_total_s(2) < 720 + 120
    assert isinstance(stk_proc_scan(), list)
    print("selftest stickTestFix ok (Audiopegel, Fehlertexte, Dauer %d/%d s)" % (STK_433_S, STK_APRS_S))
# ===== /stickTestFix =====
FXMOD_EOF
EXPECT_EDIT="bb5e8efaae8edb0a151d7335ce0d74f2f7aa5aabe9e19c1eb4c24ccfbe533974"
cat > "$W/edit-fix.py" << 'FXEDIT_EOF'
import sys
src = open(sys.argv[1]).read(); mod = open(sys.argv[3]).read()
if "# ===== stickTestFix:" in src:
    open(sys.argv[2], "w").write(src); print("schon da"); raise SystemExit(0)
def rep(a, b, n=1):
    global src
    assert src.count(a) == n, (a[:60], src.count(a)); src = src.replace(a, b)
rep("# ===== /stickTest =====\n", "# ===== /stickTest =====\n" + mod)
# Stick 2: Wartezeit bei Pause abbrechen
rep('''            while not self.main.stop and time.time() < end:
                time.sleep(0.5)
''', '''            while not self.main.stop and time.time() < end:
                time.sleep(0.5)
                if getattr(self.main, "st_pause", False):
                    break  # stickTestFix: Pause sofort, Stick 2 freigeben
''')
rep('''        last_step, end = None, t0 + 720''', '''        stk_durations(load_json(p("sdr_config.json", base), {}) or {})
        print("Dauer: 433 %d s, APRS %d s je Stick (sdr_config.json sticktest_433_s / sticktest_aprs_s)" % (STK_433_S, STK_APRS_S), flush=True)
        last_step, end = None, t0 + stk_total_s(2) + 240''')
rep('''beide Sticks nacheinander (ca. 5 min, nur Empfang) ...''', '''beide Sticks nacheinander (nur Empfang) ...''')
rep('''        selftest_sticktest()
''', '''        selftest_sticktest()
        selftest_sticktestfix()
''')
open(sys.argv[2], "w").write(src); print("geaendert")
FXEDIT_EOF
EXPECT_GUARD="49e0d796e5a2d266a23bfc1368dffdf91b616b79409045e3ffdd4328921b0b85"
cat > "$W/guard_fix.py" << 'FXGUARD_EOF'
import ast, sys
def info(fn):
    t = ast.parse(open(fn, encoding="utf-8").read()); imp, calls, bad = set(), [], 0
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False): bad += 1
        if isinstance(n, ast.Call):
            f = n.func; calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
    return imp, calls, bad
bi, bc, bb = info(sys.argv[1]); ni, nc, nb = info(sys.argv[2])
inst = "# ===== stickTestFix:" in open(sys.argv[1], encoding="utf-8").read()
allow = {"Popen": 2, "Thread": 2, "execv": 0}
err = []
if ni - bi - {"hashlib", "tempfile"}: err.append("Importe neu %s" % (ni - bi))
if nb != bb: err.append("shell=True neu")
for nm in ("send_meshtastic", "sendText", "sendData", "urlopen", "socket", "create_connection", "bind", "listen", "connect", "system", "Popen", "Thread", "Timer", "execv", "run", "call", "check_output", "HTTPServer", "serve_forever"):
    d = nc.count(nm) - bc.count(nm)
    if d != (0 if inst else allow.get(nm, 0)): err.append("Aufrufe %s %+d" % (nm, d))
src = open(sys.argv[2], encoding="utf-8").read()
blk = src[src.index("# ===== stickTestFix:"):src.index("# ===== /stickTestFix =====")]
blk = "\n".join(l for l in blk.splitlines() if not l.startswith("STK_TOOLS = "))  # nur Namensliste zum Erkennen belegter Sticks
if "mesh" in blk.lower() and "meshtastic" in blk.lower(): err.append("Block erwaehnt Meshtastic")
for w in ("rtl_tcp", "rtl_sdr", "-T", "transmit"):
    if '"%s"' % w in blk: err.append("Block nutzt " + w)
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard prepper_sdr: keine Sendestelle/Netz/Server neu, kein shell=True; neu nur Popen +%d (Testkette + rtl_eeprom-Oeffnungspruefung), Thread +%d (Leser), execv +%d" % tuple(0 if inst else allow[k] for k in ("Popen", "Thread", "execv")))
FXGUARD_EOF
EXPECT_LC="ce93e3ddcf0b05d63c62c93a67f29e114bfe5bc488c22c1c2ae372329e852e36"
cat > "$W/layout_check.py" << 'FXLC_EOF'
"""Raster-Pruefung /funk: layout_check.py SEITE.html [VORHER.html] -> 0 ok, 1 Fehler.
Haupt-Raster = div.grid mit den meisten Kacheln. Kachel = div.card, nicht in einer anderen Kachel.
Pflicht: #stickTestCard genau einmal, direktes Kind des Rasters und letztes div darin; keine Kachel ausserhalb, die es vorher nicht schon gab."""
import sys
from html.parser import HTMLParser


class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.nodes = [], []

    def handle_starttag(self, tag, attrs):
        if tag != "div":
            return
        a = dict(attrs)
        n = {"i": len(self.nodes), "cls": (a.get("class") or "").split(), "id": a.get("id") or "", "par": self.stack[-1] if self.stack else None, "kids": [], "txt": ""}
        if n["par"] is not None:
            self.nodes[n["par"]]["kids"].append(n["i"])
        self.nodes.append(n)
        self.stack.append(n["i"])

    def handle_endtag(self, tag):
        if tag == "div" and self.stack:
            self.stack.pop()

    def handle_data(self, d):
        if self.stack and len(self.nodes[self.stack[-1]]["txt"]) < 40:
            self.nodes[self.stack[-1]]["txt"] += d.strip()


def analyse(fn):
    p = P()
    p.feed(open(fn, encoding="utf-8", errors="replace").read())
    N = p.nodes

    def anc(i):
        j = N[i]["par"]
        while j is not None:
            yield j
            j = N[j]["par"]
    tiles = [n["i"] for n in N if "card" in n["cls"] and not any("card" in N[j]["cls"] for j in anc(n["i"]))]
    grids = [n["i"] for n in N if "grid" in n["cls"]]
    if not grids:
        return None, tiles, N, []
    g = max(grids, key=lambda x: sum(1 for t in tiles if x in anc(t)))
    out = [t for t in tiles if g not in anc(t)]
    return g, tiles, N, out


def sig(N, i):
    return N[i]["id"] or ("%s:%s" % (".".join(N[i]["cls"]), N[i]["txt"][:30]))


g, tiles, N, out = analyse(sys.argv[1])
err = []
if g is None:
    err.append("kein Kachel-Raster gefunden")
else:
    st = [n["i"] for n in N if n["id"] == "stickTestCard"]
    if len(st) != 1:
        err.append("#stickTestCard %d-mal" % len(st))
    else:
        s = st[0]
        if N[s]["par"] != g:
            err.append("#stickTestCard nicht direkt im Raster")
        elif N[g]["kids"][-1] != s:
            err.append("#stickTestCard nicht letzte Kachel (danach: %s)" % sig(N, N[g]["kids"][-1]))
    before = set()
    if len(sys.argv) > 2:
        g0, t0, N0, out0 = analyse(sys.argv[2])
        before = set(sig(N0, i) for i in out0)
    new_out = [sig(N, i) for i in out if N[i]["id"] != "stickTestCard" and sig(N, i) not in before]
    if new_out:
        err.append("Kacheln ausserhalb des Rasters (neu): " + ", ".join(new_out))
    print("Raster: %d Kacheln im Raster, ausserhalb (schon vorher/Absicht): %s" % (sum(1 for t in tiles if t not in out), ", ".join(sig(N, i) for i in out if N[i]["id"] != "stickTestCard") or "keine"))
if err:
    print("FEHLER Raster /funk: " + "; ".join(err)); raise SystemExit(1)
print("OK /funk: Antennentest letzte Kachel im Raster, keine Kachel neu ausserhalb")
FXLC_EOF
P="$W/patch-dfix.py"; LB="$W/dfix_block.py"; SM="$W/fix_mod.py"; SE="$W/edit-fix.py"; SG="$W/guard_fix.py"; LC="$W/layout_check.py"
for x in "$EXPECT_BLK $LB" "$EXPECT_PATCH $P" "$EXPECT_MOD $SM" "$EXPECT_EDIT $SE" "$EXPECT_GUARD $SG" "$EXPECT_LC $LC"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
if [[ "$D16" != "$BASE_DASH16" ]] && ! grep -q "# ===== stickTestFix:" "$F"; then echo "STOP: dashboard.py sha16 $D16 erwartet $BASE_DASH16 - nichts geaendert"; exit 1; fi
if [[ "$S16" != "$BASE_MOD16" ]] && ! grep -q "# ===== stickTestFix:" "$M"; then echo "STOP: prepper_sdr.py sha16 $S16 erwartet $BASE_MOD16 - nichts geaendert"; exit 1; fi
grep -q "# ===== stickTest:" "$F" && grep -q "# ===== stickTest:" "$M" && grep -q "# ===== lageTest:" "$F" || { echo "STOP: stickTest/lageTest-Guard fehlt - nichts geaendert"; exit 1; }
echo "OK Basis dashboard.py $D16 ($(wc -l < "$F") Zeilen), prepper_sdr.py $S16 ($(wc -l < "$M") Zeilen)"
SDR_ACT=$(systemctl is-active prepper-sdr 2>/dev/null || true)
[[ "$SDR_ACT" == active ]] || { echo "STOP: prepper-sdr ist nicht aktiv ($SDR_ACT) - erst Dienst pruefen, nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$SE" "$M" "$W/work/prepper_sdr.py" "$SM" >/dev/null || { echo "STOP: prepper_sdr-Basis passt nicht - nichts geaendert"; exit 1; }
python3 "$SE" "$W/work/prepper_sdr.py" "$W/work/s2.py" "$SM" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
python3 "$P" "$F" "$W/work/dashboard.py" "$LB" >/dev/null || { echo "STOP: Dashboard-Basis passt nicht - nichts geaendert"; exit 1; }
python3 "$P" "$W/work/dashboard.py" "$W/work/d2.py" "$LB" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
for py in "$SPY" "$VPY"; do
  "$py" -W error -m py_compile "$W/work/prepper_sdr.py" || { echo "STOP: py_compile prepper_sdr ($py) - nichts geaendert"; exit 1; }
done
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard - nichts geaendert"; exit 1; }
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest ($py) - nichts geaendert"; exit 1; }
  grep -q "selftest stickTestFix ok" "$W/selftest.log" || { echo "STOP: Selbsttest stickTestFix fehlt ($py)"; exit 1; }
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY: $(grep 'selftest stickTest ok' "$W/selftest.log" | cut -c1-40) / $(grep 'selftest stickTestFix ok' "$W/selftest.log")"
# ---------- 3) AST-Guard ----------
python3 "$SG" "$M" "$W/work/prepper_sdr.py" || { echo "STOP: Guard prepper_sdr - nichts geaendert"; exit 1; }
python3 - "$F" "$W/work/dashboard.py" "$LB" "$P" << 'GUARDPY' || { echo "STOP: Guard Dashboard - nichts geaendert"; exit 1; }
import ast, sys
def info(fn):
    t = ast.parse(open(fn, encoding="utf-8").read()); imp, calls, bad = set(), [], []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False): bad.append("shell=")
        if isinstance(n, ast.Call):
            f = n.func; calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
    return imp, calls, bad
bi, bc, bb = info(sys.argv[1]); ni, nc, nb = info(sys.argv[2]); li, lc, lb = info(sys.argv[3]); pi, pc, pb = info(sys.argv[4])
err = []
if ni != bi: err.append("Importe geaendert %s" % (ni ^ bi))
if len(nb) != len(bb): err.append("shell=True neu")
for nm in ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "Popen", "system", "run", "call", "check_output", "urlopen", "socket", "create_connection", "bind", "listen", "Thread", "Timer"):
    if nc.count(nm) != bc.count(nm): err.append("Aufrufe %s geaendert (%d->%d)" % (nm, bc.count(nm), nc.count(nm)))
    if nm in lc: err.append("Block ruft %s" % nm)
if nc.count("add_url_rule") != bc.count("add_url_rule"): err.append("keine neue Route erlaubt")
if nc.count("after_request") != bc.count("after_request"): err.append("kein neuer after_request erlaubt (nur Austausch _stk_after)")
if [c for c in lc if c.startswith(("send", "maybe_mesh"))]: err.append("Block: Sendeaufruf")
if li - {"re", "flask"} or pi - {"sys"}: err.append("Importe Block/Patch %s %s" % (li, pi))
blk = open(sys.argv[3], encoding="utf-8").read()
if "mesh" in blk.lower(): err.append("Block erwaehnt mesh")
if "fetch(" in blk or "XMLHttpRequest" in blk or "add_url_rule" in blk: err.append("Fix-Block darf keine Anfragen/Routen enthalten")
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard Dashboard: keine Sendestelle (send_meshtastic %d=%d), keine Prozesse/Netz/Threads, keine neue Route, kein neuer after_request (nur Austausch der /funk-Einfuegung)" % (bc.count("send_meshtastic"), nc.count("send_meshtastic")))
GUARDPY
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys,time
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
md5s() { local x; for x in "$DASH_DIR/sdr_mode.json" "$DASH_DIR/sdr_lage.json"; do if [[ -f "$x" ]]; then md5sum "$x" | cut -c1-32 | tr '\n' ' '; else printf 'fehlt '; fi; done; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 4) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK stickTestFix schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    sudo systemctl stop prepper-sdr.service || true
    for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
      [[ -f "$x.bak-sticktestfix-$TS" ]] && cp -a "$x.bak-sticktestfix-$TS" "$x.rb" && mv -f "$x.rb" "$x"
    done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "$F" "$M"; do cmp -s "$x" "$x.bak-sticktestfix-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), Stick 2 im Config: $(grep -c '"stick2"' "$DASH_DIR/sdr_config.json" || true)"
  }
  for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-sticktestfix-$TS"
    { ls -1t "$x.bak-sticktestfix-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  sudo systemctl stop prepper-sdr.service
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-sticktestfix-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-sticktestfix-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-sdr und prepper-dashboard - warte auf HTTP und SDR-Status (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  ok=0; for i in $(seq 1 60); do systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; sleep 2; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr schreibt keinen frischen Status"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 5) Rauchtest ----------
fail=0
for p in "${PAGES[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite antwortet schlechter als vorher"
for p in /api/sdr/ui /api/br24 /api/sdr/sticktest; do c=$(code_r "$B$p"); printf '  HTTP %s = %s\n' "$p" "$c"; [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" || true
grep -q 'id="stickTestCard"' "$W/pi.html" && rbx "/pi zeigt Antennentest-Kachel"
python3 "$LC" "$W/funk.html" "$W/funk0.html" || rbx "Raster /funk fehlerhaft"
c=$(code -X POST -H 'Content-Type: application/json' -H 'X-Stick-Test: 1' -d '{"action":"start"}' "$B/api/sdr/sticktest")
[[ "$c" == 403 ]] && echo "OK fremder Aufruf ohne gleichen Ursprung abgelehnt (403)" || rbx "Anforderung ohne Ursprung nicht abgelehnt ($c)"
[[ -f "$DASH_DIR/sdr_req_sticktest" ]] && rbx "Anforderungsdatei trotz 403 angelegt"
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] || rbx "/pi Sicherung veraendert ($R0/$R1)"
echo "OK /pi doPrepperRestore unveraendert ($R1)"
# ---------- 6) Stick-Test einmal (ca. 5 min, nur Empfang, im Dienst) ----------
MD0=$(md5s)
echo "=== Antennentest laeuft jetzt im Dienst prepper-sdr (Standard 2 x (120 s + 120 s + Rauschboden), ca. 10 min, nur Empfang, Plan pausiert) ==="
STR=0; "$SPY" "$M" stick-test || STR=$?
MD1=$(md5s)
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr nach Stick-Test nicht aktiv"
ok=0; T1=$(date +%s); for i in $(seq 1 40); do sdr_fresh "$T1" && { ok=1; break; }; sleep 3; done
[[ "$ok" == 1 ]] && echo "OK prepper-sdr laeuft nach dem Test normal weiter (Status frisch)" || echo "WARNUNG: SDR-Status nach Test nicht frisch"
[[ "$MD0" == "$MD1" ]] && echo "OK Modus/Lage-Dateien vorher = nachher" || echo "WARNUNG: sdr_mode/sdr_lage geaendert ($MD0 / $MD1)"
[[ "$STR" == 0 ]] || echo "WARNUNG: Stick-Test-CLI Rueckgabe $STR (Ergebnis spaeter: python3 $M stick-last)"
echo "Rollen NICHT geaendert. Tausch nur mit /funk-Kachel Antennentest 'Empfehlung uebernehmen' oder: python3 $M stick-apply"
# ---------- 7) (kein Neu-Lernen in diesem Lauf) ----------
c=$(code_r "$B/api/sdr/ui"); [[ "$c" == 200 ]] || rbx "/api/sdr/ui nach Test $c"
echo "OK /api/sdr/ui = 200 nach Test"
echo "OK guards stickTestFix(dash)=$(grep -c '# ===== stickTestFix:' "$F" || true) stickTestFix(sdr)=$(grep -c '# ===== stickTestFix:' "$M" || true) stickTest(dash)=$(grep -c '# ===== stickTest:' "$F" || true) stickTest(sdr)=$(grep -c '# ===== stickTest:' "$M" || true) lageTest=$(grep -c '# ===== lageTest:' "$F" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) piPolish2=$(grep -c '# ===== piPolish2:' "$F" || true) sdrLage=$(grep -c '# ===== sdrLage:' "$F" || true) sdrUi=$(grep -c '# ===== sdrUi:' "$F" || true)"
[[ -f "$F.bak-sticktestfix-$TS" ]] && echo "Backups: *.bak-sticktestfix-$TS (dashboard.py, prepper_sdr.py, sdr_lage.json, sdr_config.json), behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py sha16 $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen"
echo "COMMIT $COMMIT_ARG stickTestFix=1"
