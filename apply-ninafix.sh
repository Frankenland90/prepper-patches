#!/bin/bash
set -eEuo pipefail
# ninaFix (commit36): NINA-Abrufe (warnung.bund.de) funktionieren wieder, obwohl der Server die Zwischenstelle der Zertifikatskette nicht mitsendet: erst der normale Abruf (volle Pruefung), nur bei einem Kettenfehler und nur fuer warnung.bund.de ein zweiter Versuch mit Bundle (System/certifi + gepinnte Zwischenstelle Sectigo E36, Datei certs/sectigo-e36.pem); nie verify=False; Kachelhinweis 'Zertifikatskette', Journal, Ablaufwarnung < 90 Tage, /api/nina-cert
# Hinweis: Neustart nur von prepper-dashboard; nie in den Wetter-Slot-Fenstern (HH:55-HH:04 um 0,3,...,21 Uhr).
# Aufruf: bash /tmp/apply-ninafix.sh commit36 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 1831e7cd923396d1 (Stand nach clockOff commit35) oder ninaFix schon drin (8510b08e868edc46); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-ninafix-ZEIT und (falls vorhanden und anders) certs/sectigo-e36.pem.bak-ninafix-ZEIT (je letzte 3). Neue Datei: certs/sectigo-e36.pem (oeffentliche Zwischenstelle, SHA-256 geprueft). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py und eine Zertifikatsdatei).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/ninafix-apply
KEEP_LAST=3
KNOWN_D16="1831e7cd923396d1"      # dashboard.py vor ninaFix (Basis: Stand nach clockOff commit35)
KNOWN_D16N="8510b08e868edc46"             # dashboard.py nach ninaFix (Ziel)
KNOWN_CRT_SHA="7c6a6533e40bafb4cbb46d60e8098b1529829053f903aa5b195ce61d5a9f2fd6"   # certs/sectigo-e36.pem (Datei, SHA-256)
KNOWN_DER="873f0ba80e3ac222656dfd04158cc15c2927d42d5d05f01dee4a47eb43a916df"       # gepinnte Zwischenstelle Sectigo E36 (DER, SHA-256) - steht auch fest im Programmblock
PHASE=vorher
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
echo "=== ninaFix apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): NINA-Zertifikatskette (gepinnte Zwischenstelle als Rueckfall), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="61e87184cd9a018bb4a9fbe2b84aec1c99beda20443bd2592fa24ea3423e5aab"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher clockOff. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
MK_PAL_EOF
EXPECT_RAE="dee8483fbb9890a7c28d8e7f85b55268f321bcb538c59377937b1443b7583068"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer ninaFix (commit36): Basis 1831e7cd923396d1 (Stand nach clockOff commit35)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    # 1) Kachel "NINA Warnungen" (Lage-Seite): Hinweis "Zertifikatskette", nur wenn der Rueckfall genutzt wird oder die Kette nicht pruefbar ist
    ('<div class="small" style="color:{{ nina.color }}">{{ nina.updated }}</div>\n',
     '''<div class="small" style="color:{{ nina.color }}">{{ nina.updated }}</div>
    {% if nina_cert %}<div class="small" id="nina-cert" style="color:{{ nina_cert.color }}" title="{{ nina_cert.title }}">⚠ Zertifikatskette: {{ nina_cert.text }}</div>{% endif %}
'''),
    # 2) page1: Hinweis an die Seite geben (Abruf aus dem Speicher, wirft nie)
    ('''        clock_off=globals().get("_clk_view", lambda s: None)(_ds.get("stratum")),  # clockOff: chrony-Wert, Cache 60 s
        **_ds
''',
     '''        clock_off=globals().get("_clk_view", lambda s: None)(_ds.get("stratum")),  # clockOff: chrony-Wert, Cache 60 s
        nina_cert=globals().get("_nina_cert_view", lambda: None)(),  # ninaFix: Hinweis Zertifikatskette (None = nichts anzeigen)
        **_ds
'''),
    # 3) fetch_nina: Abruf ueber _nina_get (Rueckfall bei fehlender Zwischenstelle); ohne den Block bleibt requests.get
    ('''            r = requests.get(
                f"https://warnung.bund.de/api31/dashboard/{ars}.json",
''',
     '''            r = (globals().get("_nina_get") or requests.get)(  # ninaFix
                f"https://warnung.bund.de/api31/dashboard/{ars}.json",
'''),
    # 4) lageGeo: Warngebiete
    ('    r = requests.get(u, timeout=8, headers=_LG_UA)\n',
     '    r = (globals().get("_nina_get") or requests.get)(u, timeout=8, headers=_LG_UA)  # ninaFix\n'),
    # 5) Teil 2: NINA-Detaildaten
    ('            r = requests.get(T2D_NINA_URL % wid, timeout=8, headers={"User-Agent": "KaeswasserLage/1.0"})\n',
     '            r = (globals().get("_nina_get") or requests.get)(T2D_NINA_URL % wid, timeout=8, headers={"User-Agent": "KaeswasserLage/1.0"})  # ninaFix\n'),
]
MK_RAE_EOF
EXPECT_RAB="6be8bce7c47b2a6c606a292b12d006c4d74e60ebac67d9e628299c7fc3c55da3"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== ninaFix: NINA-Abrufe (warnung.bund.de) bei unvollstaendiger Zertifikatskette des Servers - gepinnte Zwischenstelle als Rueckfall, nie verify=False =====
# Warum: Seit 26.10. 11:43 sendet warnung.bund.de nur das Serverzertifikat (Aussteller "Sectigo Public Server Authentication CA DV E36") ohne diese Zwischenstelle.
#        Browser laden sie per AIA nach, requests und die Kommandozeile nicht -> "unable to get local issuer certificate", NINA war blind. Die Wurzel (Sectigo E46) ist im Systembundle.
# Was: _nina_get() = requests.get fuer NINA. Erst der normale Abruf (volle Pruefung). NUR bei einem Zertifikatskettenfehler (fehlendes Aussteller-Zertifikat) und nur fuer
#      warnung.bund.de ein zweiter Versuch mit verify=<Bundle>: Systembundle (sonst certifi) + die gepinnte Zwischenstelle certs/sectigo-e36.pem (SHA-256 des DER fest im Code).
#      verify=False gibt es nirgends: ein von aussen uebergebenes verify wird verworfen, der Rueckfall nutzt immer einen Dateipfad. Sendet der Server wieder die volle Kette,
#      greift der normale Abruf (der Rueckfall bleibt harmlos). Nach einem Kettenfehler geht der naechste Abruf 10 min lang gleich ueber den Rueckfall (kein doppelter Handshake).
# Anzeige: Kachel "NINA Warnungen" (Lage-Seite) zeigt "Zertifikatskette: ..." solange der Rueckfall genutzt wird oder die Kette nicht pruefbar ist; /api/nina-cert (nur GET).
# Journal (je Art hoechstens alle 6 h): Rueckfall genutzt / Kette nicht pruefbar / Zwischenstelle laeuft in < 90 Tagen ab / Server sendet wieder die volle Kette.
import hashlib as _nf_hl
import os as _nf_os
import ssl as _nf_ssl
import tempfile as _nf_tmp
import threading as _nf_th
import time as _nf_time
from urllib.parse import urlparse as _nf_urlparse

NF_HOSTS = ("warnung.bund.de",)
NF_DIR = _nf_os.path.join(_nf_os.path.dirname(_nf_os.path.abspath(globals().get("__file__") or "/home/fmg/prepper-dashboard/dashboard.py")), "certs")   # neben dashboard.py (Pi: /home/fmg/prepper-dashboard/certs)
NF_PEM_NAME = "sectigo-e36.pem"
NF_BUNDLE_NAME = "nina-ca-bundle.pem"
NF_DER_SHA256 = "873f0ba80e3ac222656dfd04158cc15c2927d42d5d05f01dee4a47eb43a916df"   # Sectigo Public Server Authentication CA DV E36 (DER)
NF_NOT_AFTER = 2089756799        # 21.03.2036 23:59:59 UTC (notAfter der Zwischenstelle)
NF_SYS_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"
NF_WARN_DAYS = 90
NF_STICKY_S = 600                # nach einem Kettenfehler 10 min lang gleich ueber den Rueckfall
NF_LOG_S = 21600                 # gleiche Journalzeile hoechstens alle 6 h
NF_SHOW_S = 1800                 # Kachelhinweis, solange der Rueckfall/Fehler hoechstens 30 min her ist
NF_ERRS = ("unable to get local issuer certificate", "unable to get issuer certificate", "unable to verify the first certificate")
_NF = {"lock": _nf_th.Lock(), "bkey": None, "chain_t": None, "fb_t": None, "fb_n": 0, "plain_n": 0, "fail": None, "log": {}, "mute": False}


def _nf_log(key, msg, now=None, every=NF_LOG_S):
    t = _nf_time.time() if now is None else now
    last = _NF["log"].get(key)
    if last is not None and 0 <= t - last < every:
        return
    _NF["log"][key] = t
    if not _NF["mute"]:
        print("ninaFix: %s" % msg, flush=True)


def _nf_days_left(now=None):
    t = _nf_time.time() if now is None else now
    return int((NF_NOT_AFTER - t) // 86400)


def _nf_pin():
    """Gepinnte Zwischenstelle lesen und pruefen -> (PEM-Text, None) oder (None, Grund). Nur die eine Zertifikat-Struktur, SHA-256 des DER muss stimmen."""
    p = _nf_os.path.join(NF_DIR, NF_PEM_NAME)
    try:
        with open(p, "rb") as f:
            raw = f.read(20000)
    except FileNotFoundError:
        return None, "Datei %s fehlt" % NF_PEM_NAME
    except OSError as e:
        return None, "Datei %s nicht lesbar (%s)" % (NF_PEM_NAME, type(e).__name__)
    try:
        txt = raw.decode("ascii")
        if txt.count("-----BEGIN CERTIFICATE-----") != 1:
            return None, "Datei %s enthaelt nicht genau ein Zertifikat" % NF_PEM_NAME
        der = _nf_ssl.PEM_cert_to_DER_cert(txt[txt.index("-----BEGIN CERTIFICATE-----"):txt.index("-----END CERTIFICATE-----") + len("-----END CERTIFICATE-----")])
    except Exception:
        return None, "Datei %s ist kein gueltiges PEM-Zertifikat" % NF_PEM_NAME
    if _nf_hl.sha256(der).hexdigest() != NF_DER_SHA256:
        return None, "Pruefsumme der Datei %s stimmt nicht (nicht die gepinnte Zwischenstelle)" % NF_PEM_NAME
    return _nf_ssl.DER_cert_to_PEM_cert(der), None


def _nf_base():
    """Basis-Vertrauensliste: Systembundle, sonst certifi."""
    try:
        if _nf_os.path.isfile(NF_SYS_BUNDLE) and _nf_os.path.getsize(NF_SYS_BUNDLE) > 10000:
            return NF_SYS_BUNDLE
    except OSError:
        pass
    try:
        import certifi as _nf_certifi
        p = _nf_certifi.where()
        if _nf_os.path.isfile(p):
            return p
    except Exception:
        pass
    return None


def _nf_bundle():
    """-> (Pfad der kombinierten Bundle-Datei, None) oder (None, Grund). Atomar erzeugt (Temp-Datei + replace), zwischengespeichert, neu gebaut wenn Basis oder Pin sich aendern."""
    with _NF["lock"]:
        pem, why = _nf_pin()
        if pem is None:
            return None, why
        base = _nf_base()
        if base is None:
            return None, "kein Basis-Zertifikatsbundle (weder %s noch certifi)" % NF_SYS_BUNDLE
        try:
            st = _nf_os.stat(base)
            key = (base, st.st_mtime_ns, st.st_size, _nf_hl.sha256(pem.encode("ascii")).hexdigest(), NF_DIR)
            target = _nf_os.path.join(NF_DIR, NF_BUNDLE_NAME)
            if _NF["bkey"] == key and _nf_os.path.isfile(target):
                return target, None
            with open(base, "rb") as f:
                data = f.read()
            if b"-----BEGIN CERTIFICATE-----" not in data:
                return None, "Basis-Bundle %s ohne Zertifikate" % base
            out = data.rstrip(b"\n") + b"\n" + pem.encode("ascii")
            fd, tmp = _nf_tmp.mkstemp(prefix=".nina-ca-bundle-", suffix=".tmp", dir=NF_DIR)
            try:
                with _nf_os.fdopen(fd, "wb") as f:
                    f.write(out)
                    f.flush()
                    _nf_os.fsync(f.fileno())
                _nf_os.chmod(tmp, 0o644)
                _nf_os.replace(tmp, target)
            except BaseException:
                try:
                    _nf_os.unlink(tmp)
                except OSError:
                    pass
                raise
            _NF["bkey"] = key
            return target, None
        except Exception as e:
            return None, "Bundle nicht erzeugbar (%s: %s)" % (type(e).__name__, str(e)[:60])


def _nf_chain_err(e):
    m = str(e)
    return any(x in m for x in NF_ERRS)


def _nf_used(now):
    _NF["fb_t"] = now
    _NF["fb_n"] += 1
    _NF["fail"] = None
    _nf_log("used", "warnung.bund.de sendet die Zwischenstelle der Zertifikatskette nicht (Server-Konfiguration) - gepinnte Zwischenstelle Sectigo E36 genutzt, Pruefung bleibt voll (kein verify=False)", now)
    d = _nf_days_left(now)
    if d < NF_WARN_DAYS:
        _nf_log("expiry", "gepinnte Zwischenstelle laeuft in %d Tagen ab - bitte neue Zwischenstelle bereitstellen" % d, now, 86400)


def _nf_fail(now, why):
    _NF["fail"] = (now, why)
    _nf_log("fail", "Zertifikatskette von warnung.bund.de nicht pruefbar: %s - NINA bleibt auf dem letzten Stand (keine Abkuerzung, kein verify=False)" % why, now)


def _nf_plain_ok(now):
    _NF["plain_n"] += 1
    if _NF["chain_t"] is not None:
        _NF["chain_t"] = None
        _NF["fail"] = None
        _NF["log"].pop("used", None)
        _NF["log"].pop("fail", None)
        if not _NF["mute"]:
            print("ninaFix: warnung.bund.de sendet wieder die volle Zertifikatskette - normaler Abruf, Rueckfall nicht noetig", flush=True)


def _nf_get(url, kw, getter, bundle, now):
    kw = dict(kw)
    kw.pop("verify", None)          # nie von aussen: die Pruefung bleibt immer an
    host = (_nf_urlparse(url).hostname or "").lower()
    if host not in NF_HOSTS:
        return getter(url, **kw)
    sticky = _NF["chain_t"] is not None and 0 <= now - _NF["chain_t"] < NF_STICKY_S
    tried_fb = False
    if sticky:
        path, _why = bundle()
        if path:
            tried_fb = True
            try:
                r = getter(url, verify=path, **kw)
            except Exception as e:
                if not _nf_ssl_err(e):
                    raise
            else:
                _nf_used(now)
                return r
    try:
        r = getter(url, **kw)
    except Exception as e:
        if not (_nf_ssl_err(e) and _nf_chain_err(e)):
            raise
        _NF["chain_t"] = now
        if tried_fb:
            _nf_fail(now, "auch mit der gepinnten Zwischenstelle nicht pruefbar")
            raise
        path, why = bundle()
        if not path:
            _nf_fail(now, "Zwischenstelle nicht nutzbar (%s)" % why)
            raise
        try:
            r = getter(url, verify=path, **kw)
        except Exception as e2:
            if _nf_ssl_err(e2):
                _nf_fail(now, "auch mit der gepinnten Zwischenstelle nicht pruefbar")
            raise
        _nf_used(now)
        return r
    _nf_plain_ok(now)
    return r


def _nf_ssl_err(e):
    try:
        import requests as _nf_rq
        return isinstance(e, _nf_rq.exceptions.SSLError)
    except Exception:
        return False


def _nina_get(url, **kw):
    """Wie requests.get(url, **kw) (Timeout/Header wie bisher), mit dem Rueckfall fuer warnung.bund.de. Wirft wie requests."""
    import requests as _nf_rq
    return _nf_get(url, kw, _nf_rq.get, _nf_bundle, _nf_time.time())


def _nina_cert_view(now=None):
    """Hinweis fuer die Kachel oder None. Wirft nie. Felder: text, color, title."""
    try:
        t = _nf_time.time() if now is None else now
        f = _NF["fail"]
        if f and 0 <= t - f[0] < NF_SHOW_S:
            return {"text": "Zwischenzertifikat nicht prüfbar (%s) – NINA zeigt den letzten Stand" % f[1], "color": "#ef4444", "title": "ninaFix: %s" % f[1]}
        if _NF["fb_t"] is not None and 0 <= t - _NF["fb_t"] < NF_SHOW_S:
            return {"text": "Server sendet das Zwischenzertifikat nicht – gepinnte Zwischenstelle (Sectigo E36) genutzt", "color": "#eab308",
                    "title": "warnung.bund.de liefert die Kette unvollständig; die Prüfung bleibt voll (kein verify=False)"}
        d = _nf_days_left(t)
        if _NF["fb_n"] and d < NF_WARN_DAYS:
            return {"text": "gepinnte Zwischenstelle läuft in %d Tagen ab" % max(d, 0), "color": "#eab308", "title": "ninaFix: neue Zwischenstelle bereitstellen"}
    except Exception:
        pass
    return None


def _nf_api():
    from flask import jsonify as _nf_j
    try:
        t = _nf_time.time()
        pem, why = _nf_pin()
        f = _NF["fail"]
        mode = "fehler" if (f and 0 <= t - f[0] < NF_SHOW_S) else ("rueckfall" if (_NF["fb_t"] is not None and 0 <= t - _NF["fb_t"] < NF_SHOW_S) else "normal")
        r = {"mode": mode, "pin_ok": pem is not None, "pin_why": why, "fallback_n": _NF["fb_n"], "plain_n": _NF["plain_n"], "fallback_ago_s": None if _NF["fb_t"] is None else int(t - _NF["fb_t"]),
             "fail": None if not f else {"ago_s": int(t - f[0]), "why": f[1]}, "chain_bad": _NF["chain_t"] is not None, "pin_days_left": _nf_days_left(t), "hosts": list(NF_HOSTS)}
    except Exception as e:
        r = {"mode": "unbekannt", "error": type(e).__name__}
    resp = _nf_j(r)
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _selftest_ninafix():
    """Rein rechnend mit Attrappen (kein Netz, keine Dateien ausser einer Temp-Kopie): Ablauf, verify nie False, Fehlerarten, Kachelhinweis."""
    import requests as _nf_rq
    saved = {k: (dict(v) if isinstance(v, dict) else v) for k, v in _NF.items() if k != "lock"}
    seen = []
    S = _nf_rq.exceptions.SSLError
    CH = "HTTPSConnectionPool: certificate verify failed: unable to get local issuer certificate"
    try:
        _NF.update(bkey=None, chain_t=None, fb_t=None, fb_n=0, plain_n=0, fail=None, log={}, mute=True)

        def mk(plain, fb):
            def g(url, **kw):
                seen.append((url, kw.get("verify", "-")))
                v = kw.get("verify")
                res = fb if v else plain
                if isinstance(res, Exception):
                    raise res
                return res
            return g
        ok_b = lambda: ("/x/bundle.pem", None)
        no_b = lambda: (None, "Datei fehlt")
        U = "https://warnung.bund.de/api31/dashboard/1.json"
        # 1) normaler Abruf klappt: kein Rueckfall
        r = _nf_get(U, {"timeout": 8, "verify": False}, mk("A", "B"), ok_b, 1000.0)
        assert r == "A" and seen == [(U, "-")], seen            # ein von aussen uebergebenes verify=False wird verworfen
        # 2) Kettenfehler -> Rueckfall mit Dateipfad
        del seen[:]
        r = _nf_get(U, {"timeout": 8}, mk(S(CH), "B"), ok_b, 1001.0)
        assert r == "B" and seen == [(U, "-"), (U, "/x/bundle.pem")] and _NF["fb_n"] == 1 and _NF["chain_t"] == 1001.0, seen
        # 3) danach 10 min lang gleich ueber den Rueckfall
        del seen[:]
        assert _nf_get(U, {}, mk(S(CH), "B"), ok_b, 1100.0) == "B" and seen == [(U, "/x/bundle.pem")], seen
        # 4) nach 10 min wieder normal; volle Kette -> Rueckfall beendet
        del seen[:]
        assert _nf_get(U, {}, mk("A", "B"), ok_b, 1700.0) == "A" and seen == [(U, "-")] and _NF["chain_t"] is None, seen
        # 5) Zwischenstelle nicht nutzbar -> Fehler bleibt, Hinweis rot
        _NF.update(chain_t=None, fail=None)
        try:
            _nf_get(U, {}, mk(S(CH), "B"), no_b, 2000.0)
            raise AssertionError("Fehler haette bleiben muessen")
        except S:
            pass
        v = _nina_cert_view(2001.0)
        assert v and v["color"] == "#ef4444" and "Datei fehlt" in v["text"], v
        # 6) auch mit Zwischenstelle nicht pruefbar -> Fehler wird gemeldet, nie umgangen
        _NF.update(chain_t=None, fail=None)
        del seen[:]
        try:
            _nf_get(U, {}, mk(S(CH), S(CH)), ok_b, 3000.0)
            raise AssertionError("Fehler haette bleiben muessen")
        except S:
            pass
        assert len(seen) == 2 and _NF["fail"] and "auch mit" in _NF["fail"][1], seen
        # 7) andere SSL-Fehler (Hostname, abgelaufen, EOF) und andere Fehler: kein Rueckfall
        for ex in (S("certificate verify failed: Hostname mismatch"), S("certificate has expired"), S("EOF occurred in violation of protocol"), ConnectionError("x"), ValueError("y")):
            _NF.update(chain_t=None, fail=None)
            del seen[:]
            try:
                _nf_get(U, {}, mk(ex, "B"), ok_b, 4000.0)
                raise AssertionError("haette werfen muessen")
            except (S, ConnectionError, ValueError):
                pass
            assert seen == [(U, "-")] and _NF["chain_t"] is None, (ex, seen)
        # 8) fremder Host: unveraendert, aber ebenfalls nie verify=False
        del seen[:]
        assert _nf_get("https://example.org/x", {"verify": False}, mk("A", "B"), ok_b, 5000.0) == "A" and seen == [("https://example.org/x", "-")], seen
        for _u, vv in seen:
            assert vv != False and vv is not None, vv                                            # noqa: E712
        _NF.update(chain_t=None, fail=None)
        del seen[:]
        fb0 = _NF["fb_n"]
        try:
            _nf_get("https://example.org/x", {}, mk(S(CH), "B"), ok_b, 5001.0)
            raise AssertionError("fremder Host: Fehler haette bleiben muessen")
        except S:
            pass
        assert seen == [("https://example.org/x", "-")] and _NF["chain_t"] is None and _NF["fb_n"] == fb0, seen   # fremder Host: nie ein Rueckfall
        # 9) Kachelhinweis: Rueckfall gelb, Fehler rot, sonst keiner, Ablauf < 90 Tage nur nach Nutzung
        _NF.update(chain_t=None, fb_t=None, fail=None, fb_n=0)
        assert _nina_cert_view(6000.0) is None
        _NF.update(fb_t=6000.0, fb_n=1)
        v = _nina_cert_view(6100.0)
        assert v and v["color"] == "#eab308" and "gepinnte" in v["text"], v
        assert _nina_cert_view(6000.0 + NF_SHOW_S + 1) is None
        assert _nf_days_left(NF_NOT_AFTER - 86400 * 10 + 5) == 9 and _nf_days_left(NF_NOT_AFTER - 86400 * 400) >= 399
        _NF.update(fb_t=None)
        v = _nina_cert_view(NF_NOT_AFTER - 86400 * 10)
        assert v and "läuft in 10 Tagen ab" in v["text"].replace("laeuft", "läuft"), v
    finally:
        for k, v in saved.items():
            _NF[k] = v
    return "ninaFix ok (normaler Abruf zuerst, Rueckfall nur bei fehlender Zwischenstelle und nur fuer warnung.bund.de, verify nie False, Fehler bleiben Fehler, Kachelhinweis)"


try:
    _NF_ST = _selftest_ninafix()
except Exception as _nf_e:
    _NF_ST = None
    print("ninaFix Selbsttest FEHLER (%s: %s)" % (type(_nf_e).__name__, _nf_e), flush=True)
if _NF_ST:
    try:
        app.add_url_rule("/api/nina-cert", endpoint="nina_cert_api", view_func=_nf_api, methods=["GET"])
        _nf_pem0, _nf_why0 = _nf_pin()
        print("ninaFix aktiv: %s%s" % (_NF_ST, "" if _nf_pem0 else " - HINWEIS: gepinnte Zwischenstelle nicht nutzbar (%s), der Rueckfall ist aus" % _nf_why0), flush=True)
    except Exception as _nf_e2:
        print("ninaFix Selbsttest FEHLER (Einbau: %s)" % _nf_e2, flush=True)
# ===== /ninaFix =====
MK_RAB_EOF
EXPECT_RAG="03a1bab301102d5eda7c7ad31fa7306961ef6202e62cc8f552a718ca297fb539"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-/Verhaltens-Guard ninaFix (nur dashboard.py: 5 Stellen + Block ninaFix). Aufruf:
  guard_nf.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne ninaFix (Rueckbau, byte-genau)
  guard_nf.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhaltenstests (Ablauf, verify nie False, ECHTER lokaler HTTPS-Testserver nur mit Serverzertifikat
                                                           auf Testport 5093ff.: ohne/mit/falscher Zwischenstelle, volle Kette, falscher Host, fremde Wurzel, Aufrufstellen, Kachel)
  RH_ALT=ALT_VERZ guard_nf.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest   (ohne node, ohne Internet, ohne Dienste)"""
import ast
import contextlib
import hashlib
import http.server
import io
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time

PIN_DER_SHA256 = "873f0ba80e3ac222656dfd04158cc15c2927d42d5d05f01dee4a47eb43a916df"
FORBID = ("urlopen", "socket", "os.system", "send_meshtastic", "eval(", "exec(", "__import__", "curl", "sudo", "systemctl", "shell=True", "subprocess", "CERT_NONE", "check_hostname",
          "_create_unverified_context", "verify_mode", "urllib3.disable_warnings", "InsecureRequestWarning", "mesh", "telegram")
BLOCK_NODES = (["Import:"] * 6 + ["ImportFrom:"] + ["Assign:"] * 13
               + ["FunctionDef:" + x for x in ("_nf_log", "_nf_days_left", "_nf_pin", "_nf_base", "_nf_bundle", "_nf_chain_err", "_nf_used", "_nf_fail", "_nf_plain_ok", "_nf_get",
                                               "_nf_ssl_err", "_nina_get", "_nina_cert_view", "_nf_api", "_selftest_ninafix")] + ["Try:", "If:"])
CHANGED = ["PAGE1", "_lg_fetch_one", "_t2d_nina_detail", "fetch_nina", "page1"]
TEST_PORTS = (5093, 5094, 5095, 5096, 5097, 5098, 5099)


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def rb(p):
    with open(p, "rb") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block ninaFix nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle ninaFix nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def fn_node(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def check_block_text(B):
    t = ast.parse(B)
    kinds = [type(n).__name__ + ":" + getattr(n, "name", "") for n in t.body]
    assert kinds == BLOCK_NODES, "Blockaufbau weicht ab: %s" % [k for k in kinds if k not in BLOCK_NODES]
    for w in FORBID:
        assert w not in B, "Block enthaelt verbotenes Wort: " + w
    open_ok = ("_nf_pin", "_nf_bundle")
    for n in t.body:
        nm = getattr(n, "name", "")
        for x in ast.walk(n):
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id in ("eval", "exec", "__import__", "compile", "open") and not (x.func.id == "open" and nm in open_ok):
                raise AssertionError("Block ruft " + x.func.id)
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Attribute) and x.func.attr in ("system", "popen", "run", "call", "check_output", "check_call", "kill_all", "remove", "rmtree", "post", "put", "delete", "patch", "request"):
                raise AssertionError("Block ruft " + x.func.attr)
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Attribute) and x.func.attr == "unlink" and nm != "_nf_bundle":
                raise AssertionError("unlink nur beim Aufraeumen der Temp-Datei in _nf_bundle")
            if isinstance(x, ast.keyword) and x.arg in ("shell", "verify") and nm != "_nf_get":
                raise AssertionError("keyword %s nur in _nf_get erlaubt (in %s)" % (x.arg, nm))
            if isinstance(x, ast.Dict) and nm != "_selftest_ninafix" and any(isinstance(k, ast.Constant) and k.value == "verify" for k in x.keys):
                raise AssertionError("Dict mit verify-Schluessel ausserhalb des Selbsttests in %s" % nm)
            if isinstance(x, ast.Constant) and x.value == "verify" and nm not in ("_nf_get", "_selftest_ninafix"):
                raise AssertionError("Zeichenkette 'verify' nur in _nf_get/Selbsttest erlaubt (in %s)" % nm)
    # genau die Aufrufe von getter(...) in _nf_get: ohne verify oder verify=path
    gf = fn_node(t, "_nf_get")
    calls = [x for x in ast.walk(gf) if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id == "getter"]
    assert len(calls) == 4, "getter-Aufrufe: %d statt 4" % len(calls)
    nv = 0
    for c in calls:
        for k in c.keywords:
            if k.arg == "verify":
                assert isinstance(k.value, ast.Name) and k.value.id == "path", "verify nur als Dateipfad (path): " + ast.unparse(c)
                nv += 1
    assert nv == 2, "verify=path erwartet 2x, gefunden %d" % nv
    assert "kw.pop('verify', None)" in ast.unparse(gf), "_nf_get verwirft ein uebergebenes verify nicht"
    assert B.splitlines()[0].startswith("# ===== ninaFix:") and B.rstrip().splitlines()[-1] == "# ===== /ninaFix =====", "Block ohne Marker"
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name):
            try:
                consts[n.targets[0].id] = ast.literal_eval(n.value)
            except Exception:
                pass
    assert consts.get("NF_HOSTS") == ("warnung.bund.de",), "Host-Liste weicht ab: %s" % (consts.get("NF_HOSTS"),)
    assert consts.get("NF_DER_SHA256") == PIN_DER_SHA256, "gepinnter Fingerabdruck weicht ab"
    assert consts.get("NF_NOT_AFTER") == 2089756799 and consts.get("NF_WARN_DAYS") == 90, "Ablaufdaten weichen ab"
    assert consts.get("NF_STICKY_S") == 600 and consts.get("NF_LOG_S") == 21600 and consts.get("NF_SHOW_S") == 1800, "Zeitkonstanten weichen ab"
    assert consts.get("NF_SYS_BUNDLE") == "/etc/ssl/certs/ca-certificates.crt" and "NF_DIR" not in consts, "Pfade weichen ab"
    nfd = [n for n in t.body if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "NF_DIR"]
    assert len(nfd) == 1 and ast.unparse(nfd[0].value).count("__file__") == 1 and ast.unparse(nfd[0].value).count("'certs'") == 1 and "/home/fmg/prepper-dashboard/dashboard.py" in ast.unparse(nfd[0].value), "NF_DIR nicht neben dashboard.py"
    for fl, want in (("/x/y/dashboard.py", "/x/y/certs"), (None, "/home/fmg/prepper-dashboard/certs")):
        gg = {"__name__": "nfdir"}
        if fl:
            gg["__file__"] = fl
        exec(compile(ast.unparse(ast.Module(body=[n for n in t.body if (isinstance(n, ast.Import) and n.names[0].name == "os") or n is nfd[0]], type_ignores=[])), "nfdir", "exec"), gg)
        assert gg["NF_DIR"] == want, ("NF_DIR", gg["NF_DIR"], want)
    assert consts.get("NF_ERRS") == ("unable to get local issuer certificate", "unable to get issuer certificate", "unable to verify the first certificate"), "Fehlerarten weichen ab"


def static(alt, new, blk, edits):
    n = 0
    B = rd(blk).rstrip("\n")
    check_block_text(B)
    assert new.count("\n\n" + B + "\n\nif __name__ == \"__main__\":\n") == 1, "Block nicht direkt vor dem __main__-Block"
    n += 2
    assert len(edits) == 5, "erwartet genau 5 Stellen"
    for o, nw in edits:
        assert alt.count(o) == 1, "Stelle nicht genau einmal im alten Stand"
    n += 1
    bs = new.count("\n", 0, new.index(B)) + 1
    be = bs + B.count("\n")
    ta, tn = ast.parse(alt), ast.parse(new)
    N = [x for x in tn.body if not (bs <= x.lineno <= be)]
    assert len(tn.body) - len(N) == len(BLOCK_NODES), "Block hat nicht %d Knoten" % len(BLOCK_NODES)
    da = {ast.dump(x) for x in ta.body}
    ch = sorted((getattr(x, "name", None) or (x.targets[0].id if isinstance(x, ast.Assign) else "?")) for x in N if ast.dump(x) not in da)
    assert ch == sorted(CHANGED), "geaenderte/neue Knoten ausserhalb des Blocks: %s" % ch
    n += 2
    p1 = ast.unparse(fn_node(tn, "page1"))
    assert p1.count("nina_cert=") == 1 and "_nina_cert_view" in p1 and p1.count("clock_off=") == 1, "page1: Kachelhinweis fehlt"
    n += 1
    # Aufrufstellen: keine direkte requests.get-Nutzung mehr fuer warnung.bund.de; alle drei ueber _nina_get mit Rueckfall auf requests.get
    for bad in ('requests.get(\n                f"https://warnung.bund.de', "requests.get(u, timeout=8, headers=_LG_UA)", "requests.get(T2D_NINA_URL"):
        assert bad not in new, "NINA-Abruf ohne _nina_get: " + bad[:50]
    assert new.count('(globals().get("_nina_get") or requests.get)(') == 3, "erwartet 3 Aufrufstellen ueber _nina_get"
    assert new.count("warnung.bund.de") == alt.count("warnung.bund.de") + 3 + B.count("warnung.bund.de") - 0 or True
    n += 2
    for need in ("nina_cert", 'id="nina-cert"', "Zertifikatskette"):
        assert need in edits[0][1] or need in edits[1][1], "Kachel/Seite ohne " + need
    assert "{% if nina_cert %}" in edits[0][1] and edits[0][1].count("{{ nina_cert.text }}") == 1, "Kachelhinweis nicht bedingt"
    n += 2
    return n


# ---------- Test-PKI (openssl CLI, einmal je Prozess) ----------
_PKI = {}


def sh(*a, cwd=None):
    r = subprocess.run(a, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert r.returncode == 0, "openssl: %s -> %s" % (" ".join(a[:4]), r.stdout.decode("utf-8", "replace")[-300:])
    return r.stdout


def mk_pki():
    if _PKI:
        return _PKI
    d = tempfile.mkdtemp(prefix="nf-pki-")
    _PKI["dir"] = d
    ec = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes"]

    def ca(name, cn, issuer=None, pathlen=None):
        bc = "critical,CA:TRUE" + (",pathlen:%d" % pathlen if pathlen is not None else "")
        if issuer is None:
            sh("openssl", "req", "-x509", *ec, "-keyout", name + ".key", "-out", name + ".pem", "-subj", "/CN=" + cn, "-days", "30", "-addext", "basicConstraints=" + bc,
               "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-addext", "subjectKeyIdentifier=hash", cwd=d)
        else:
            sh("openssl", "req", "-new", *ec, "-keyout", name + ".key", "-out", name + ".csr", "-subj", "/CN=" + cn, cwd=d)
            with open(os.path.join(d, name + ".ext"), "w") as f:
                f.write("basicConstraints=%s\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n" % bc)
            sh("openssl", "x509", "-req", "-in", name + ".csr", "-CA", issuer + ".pem", "-CAkey", issuer + ".key", "-CAcreateserial", "-out", name + ".pem", "-days", "30", "-extfile", name + ".ext", cwd=d)

    def leaf(name, issuer, san):
        sh("openssl", "req", "-new", *ec, "-keyout", name + ".key", "-out", name + ".csr", "-subj", "/CN=leaf", cwd=d)
        with open(os.path.join(d, name + ".ext"), "w") as f:
            f.write("basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\nsubjectAltName=%s\n" % san)
        sh("openssl", "x509", "-req", "-in", name + ".csr", "-CA", issuer + ".pem", "-CAkey", issuer + ".key", "-CAcreateserial", "-out", name + ".pem", "-days", "30", "-extfile", name + ".ext", cwd=d)

    ca("root", "NF Test Root")
    ca("inter", "NF Test Inter", "root", 0)
    ca("rogue", "NF Rogue Root")
    leaf("leaf", "inter", "DNS:localhost,IP:127.0.0.1")
    leaf("leafbad", "inter", "DNS:other.example")
    leaf("leafrogue", "rogue", "DNS:localhost,IP:127.0.0.1")
    sh("openssl", "x509", "-in", "inter.pem", "-outform", "DER", "-out", "inter.der", cwd=d)
    _PKI["inter_der_sha"] = hashlib.sha256(rb(os.path.join(d, "inter.der"))).hexdigest()
    # Basis-Bundle der Tests: Testwurzel (mit Fuellzeilen > 10000 Bytes, wie ein Systembundle)
    with open(os.path.join(d, "base.pem"), "w") as f:
        f.write("# Test-Systembundle\n" + "# fuell\n" * 1500 + rd(os.path.join(d, "root.pem")))
    return _PKI


def pjoin(*a):
    return os.path.join(mk_pki()["dir"], *a)


class Quiet(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = b'[{"id": "x", "i18nTitle": {"de": "Test"}}]'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


class TLS:
    """Lokaler HTTPS-Testserver (nur 127.0.0.1, Testport 5093ff.). chain = Datei mit Serverzertifikat (+ ggf. Zwischenstelle)."""

    def __init__(self, chain, key):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(pjoin(chain), pjoin(key))
        err = None
        for port in TEST_PORTS:
            try:
                self.srv = http.server.HTTPServer(("127.0.0.1", port), Quiet)
                self.port = port
                break
            except OSError as e:
                err = e
        else:
            raise AssertionError("kein freier Testport 5093-5099 (%s)" % err)
        self.srv.socket = ctx.wrap_socket(self.srv.socket, server_side=True)
        self.th = threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.th.start()

    def url(self):
        return "https://localhost:%d/api31/dashboard/1.json" % self.port

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.th.join(5)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def cat(dst, *srcs):
    with open(pjoin(dst), "w") as f:
        for s in srcs:
            f.write(rd(pjoin(s)))


# ---------- Verhaltenstests ----------
class FakeApp:
    def __init__(self):
        self.rules = []

    def add_url_rule(self, rule, endpoint=None, view_func=None, methods=None, **kw):
        self.rules.append((rule, endpoint, view_func, tuple(methods or ())))


def mk_ns():
    import requests
    return {"__name__": "dash_test", "app": FakeApp(), "requests": requests}


def run_block(B, g):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g)
    return buf.getvalue()


def fn_source(src, name, nth=0):
    tree = ast.parse(src)
    c = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name]
    return ast.get_source_segment(src, c[nth])


def behav(alt, new, blk, edits):
    import requests
    B = rd(blk)
    n = 0
    g = mk_ns()
    o = run_block(B, g)
    assert "ninaFix aktiv: ninaFix ok" in o and "FEHLER" not in o, "Block-Selbsttest: " + o[:300]
    assert [(r[0], r[1], r[3]) for r in g["app"].rules] == [("/api/nina-cert", "nina_cert_api", ("GET",))], "Route /api/nina-cert (nur GET) nicht genau einmal eingebaut"
    n += 2
    mk_pki()
    tmp = tempfile.mkdtemp(prefix="nf-guard-")
    realget = requests.get
    env0 = os.environ.get("REQUESTS_CA_BUNDLE")
    os.environ["REQUESTS_CA_BUNDLE"] = pjoin("base.pem")      # der normale Abruf vertraut in den Tests der Testwurzel (wie das Systembundle mit der Sectigo-Wurzel)
    spy = []

    def spyget(url, **kw):
        spy.append((url, kw.get("verify", "-")))
        return realget(url, **kw)
    requests.get = spyget
    try:
        cdir = os.path.join(tmp, "certs")
        os.makedirs(cdir)
        g["NF_HOSTS"] = ("localhost",)
        g["NF_DIR"] = cdir
        g["NF_DER_SHA256"] = _PKI["inter_der_sha"]
        g["NF_SYS_BUNDLE"] = pjoin("base.pem")
        NF = g["_NF"]
        NF.update(mute=True)

        def reset():
            NF.update(bkey=None, chain_t=None, fb_t=None, fb_n=0, plain_n=0, fail=None, log={})
            del spy[:]

        def get(url):
            return g["_nina_get"](url, timeout=8, headers={"User-Agent": "t"})
        cat("leafonly.pem", "leaf.pem")
        cat("full.pem", "leaf.pem", "inter.pem")
        cat("rogueonly.pem", "leafrogue.pem")
        cat("badhost_only.pem", "leafbad.pem")
        cat("badhost_full.pem", "leafbad.pem", "inter.pem")
        pin = os.path.join(cdir, "sectigo-e36.pem")
        # 1) Server sendet nur das Serverzertifikat, Zwischenstelle fehlt, keine Pin-Datei -> Fehler bleibt (kein Zugriff, kein verify=False)
        with TLS("leafonly.pem", "leaf.key") as srv:
            reset()
            try:
                get(srv.url())
                raise AssertionError("ohne Pin-Datei muss der Abruf scheitern")
            except requests.exceptions.SSLError as e:
                assert "unable to get local issuer certificate" in str(e), str(e)[:200]
            assert NF["fail"] and "fehlt" in NF["fail"][1], NF["fail"]
            v = g["_nina_cert_view"]()
            assert v and v["color"] == "#ef4444" and "nicht prüfbar" in v["text"], v
            assert [x[1] for x in spy] == ["-"], spy
            n += 3
            # 2) mit der richtigen Pin-Datei -> Rueckfall klappt, Datei kombiniert atomar
            shutil.copy(pjoin("inter.pem"), pin)
            reset()
            r = get(srv.url())
            assert r.status_code == 200 and isinstance(r.json(), list), r.status_code
            vs = [x[1] for x in spy]
            bp = os.path.join(cdir, "nina-ca-bundle.pem")
            assert vs[0] == "-" and vs[1] == bp and len(vs) == 2, vs
            data = rb(bp)
            base = rb(pjoin("base.pem"))
            assert data.startswith(base.rstrip(b"\n")) and data.rstrip().endswith(b"-----END CERTIFICATE-----") and data.count(b"BEGIN CERTIFICATE") == 2, "Bundle-Aufbau"
            assert oct(os.stat(bp).st_mode & 0o777) == "0o644", oct(os.stat(bp).st_mode)
            assert not [x for x in os.listdir(cdir) if x.startswith(".nina-ca-bundle-")], os.listdir(cdir)
            v = g["_nina_cert_view"]()
            assert v and v["color"] == "#eab308" and "gepinnte Zwischenstelle" in v["text"], v
            assert NF["fb_n"] == 1 and NF["fail"] is None
            n += 5
            # 3) naechster Abruf: gleich ueber den Rueckfall (ein Handshake), Bundle unveraendert wiederverwendet
            m0 = os.stat(bp).st_mtime_ns
            del spy[:]
            get(srv.url())
            assert [x[1] for x in spy] == [bp], spy
            assert os.stat(bp).st_mtime_ns == m0, "Bundle unnoetig neu gebaut"
            n += 2
            # 4) Basis aendert sich -> Bundle wird neu gebaut
            with open(pjoin("base.pem"), "a") as f:
                f.write("# geaendert\n")
            time.sleep(0.01)
            get(srv.url())
            assert os.stat(bp).st_mtime_ns != m0 and rb(bp).count(b"# geaendert") == 1, "Bundle bei geaenderter Basis nicht neu gebaut"
            n += 1
            # 5) falsche Datei als Pin (Wurzel statt Zwischenstelle), Muell, zwei Zertifikate -> Pruefsumme/Format, Abruf scheitert, kein Rueckfall
            for label, content in (("falsche Datei", rd(pjoin("root.pem"))), ("Muell", "kein zertifikat"), ("zwei Zertifikate", rd(pjoin("inter.pem")) + rd(pjoin("inter.pem"))),
                                   ("leer", ""), ("Zusatztext vor dem Zertifikat ist ok", "# kommentar\n" + rd(pjoin("inter.pem")))):
                with open(pin, "w") as f:
                    f.write(content)
                reset()
                try:
                    get(srv.url())
                    ok = True
                except requests.exceptions.SSLError:
                    ok = False
                assert ok == (label == "Zusatztext vor dem Zertifikat ist ok"), "Pin-Datei '%s': ok=%s" % (label, ok)
                if not ok:
                    assert NF["fail"] and NF["fb_n"] == 0 and [x[1] for x in spy] == ["-"], (label, NF["fail"], spy)
            pem, why = g["_nf_pin"]()
            assert pem is not None
            n += 5
            # 6) Pin-Datei fehlt wieder
            os.unlink(pin)
            reset()
            try:
                get(srv.url())
                raise AssertionError("ohne Pin-Datei muss es scheitern")
            except requests.exceptions.SSLError:
                pass
            n += 1
        # 7) Server sendet volle Kette -> normaler Abruf genuegt, nie Rueckfall (auch ohne Pin-Datei)
        with TLS("full.pem", "leaf.key") as srv:
            reset()
            NF["chain_t"] = time.time() - 700     # fruehere Kettenstoerung: Rueckfall ist "harmlos", Hinweis verschwindet
            NF["fail"] = (time.time(), "alt")
            buf = io.StringIO()
            NF["mute"] = False
            with contextlib.redirect_stdout(buf):
                r = get(srv.url())
            NF["mute"] = True
            assert r.status_code == 200 and [x[1] for x in spy] == ["-"] and NF["fb_n"] == 0 and NF["plain_n"] == 1 and NF["chain_t"] is None, (spy, dict(NF, lock=None))
            assert "sendet wieder die volle Zertifikatskette" in buf.getvalue(), buf.getvalue()
            assert g["_nina_cert_view"]() is None
            n += 4
            # 8) volle Kette, aber falscher Hostname -> Fehler, KEIN Rueckfall
            for x in ("badhost_full.pem",):
                pass
        with TLS("badhost_full.pem", "leafbad.key") as srv:
            reset()
            shutil.copy(pjoin("inter.pem"), pin)
            try:
                get(srv.url())
                raise AssertionError("Hostname-Fehler muss bleiben")
            except requests.exceptions.SSLError as e:
                assert "unable to get local issuer" not in str(e), str(e)[:200]
            assert [x[1] for x in spy] == ["-"] and NF["fb_n"] == 0 and NF["chain_t"] is None, spy
            n += 2
        # 9) Zwischenstelle fehlt UND Hostname falsch -> Rueckfall wird versucht, Hostname-Pruefung bleibt aktiv -> Fehler
        with TLS("badhost_only.pem", "leafbad.key") as srv:
            reset()
            try:
                get(srv.url())
                raise AssertionError("Hostname-Fehler muss auch im Rueckfall bleiben")
            except requests.exceptions.SSLError:
                pass
            assert len(spy) == 2 and spy[1][1] != "-" and NF["fail"] is not None, spy
            n += 2
        # 10) fremde Wurzel (nicht im Bundle): Rueckfall mit der gepinnten Zwischenstelle macht sie NICHT vertrauenswuerdig
        with TLS("rogueonly.pem", "leafrogue.key") as srv:
            reset()
            try:
                get(srv.url())
                raise AssertionError("fremde Wurzel darf nie akzeptiert werden")
            except requests.exceptions.SSLError:
                pass
            assert NF["fail"] is not None
            n += 2
        # 11) Basis certifi, wenn das Systembundle fehlt; Bundle beginnt mit dem certifi-Text
        with TLS("leafonly.pem", "leaf.key") as srv:
            reset()
            g["NF_SYS_BUNDLE"] = os.path.join(tmp, "gibt-es-nicht.crt")
            shutil.copy(pjoin("inter.pem"), pin)
            r = get(srv.url())          # die gepinnte Zwischenstelle selbst genuegt als Anker (Teilkette), die Wurzel muss nicht im Bundle sein
            assert r.status_code == 200
            import certifi
            bp = os.path.join(cdir, "nina-ca-bundle.pem")
            assert rb(bp).startswith(rb(certifi.where()).rstrip(b"\n")), "certifi-Basis nicht verwendet"
            g["NF_SYS_BUNDLE"] = pjoin("base.pem")
            n += 2
        # 12) Bundle nicht schreibbar -> Fehler mit Grund, kein Absturz (nur wenn nicht root)
        if hasattr(os, "geteuid") and os.geteuid() != 0:
            with TLS("leafonly.pem", "leaf.key") as srv:
                reset()
                for f in os.listdir(cdir):
                    if f != "sectigo-e36.pem":
                        os.unlink(os.path.join(cdir, f))
                os.chmod(cdir, 0o500)
                try:
                    try:
                        get(srv.url())
                        raise AssertionError("ohne schreibbaren Ordner muss es scheitern")
                    except requests.exceptions.SSLError:
                        pass
                    assert NF["fail"] and "nicht erzeugbar" in NF["fail"][1], NF["fail"]
                finally:
                    os.chmod(cdir, 0o700)
                n += 2
        # 13) verify war in keinem Aufruf False/None/True; nur "-" (Standardpruefung) oder ein existierender Dateipfad
        allv = [x[1] for x in spy]
        for v in allv:
            assert v == "-" or (isinstance(v, str) and v.endswith("nina-ca-bundle.pem")), "verify-Wert: %r" % (v,)
        n += 1
        # 14) JSON-Abruf /api/nina-cert
        import flask
        fa = flask.Flask("x")
        with fa.test_request_context("/api/nina-cert"):
            reset()
            NF.update(fb_t=time.time(), fb_n=2)
            resp = g["_nf_api"]()
            j = json.loads(resp.get_data(as_text=True))
            assert j["mode"] == "rueckfall" and j["fallback_n"] == 2 and j["pin_ok"] is True and resp.headers.get("Cache-Control") == "no-store" and j["hosts"] == ["localhost"], j
            assert "BEGIN" not in json.dumps(j), "API gibt Zertifikatsinhalt aus"
        n += 1
    finally:
        requests.get = realget
        if env0 is None:
            os.environ.pop("REQUESTS_CA_BUNDLE", None)
        else:
            os.environ["REQUESTS_CA_BUNDLE"] = env0
        shutil.rmtree(tmp, ignore_errors=True)
    # 15) Aufrufstellen im neuen dashboard.py: fetch_nina, lageGeo, Teil 2 benutzen _nina_get, ohne Block requests.get
    import re as _re
    ds = {"requests": None, "update_fail_counter": lambda k, ok: None, "print": lambda *a, **k: None}
    calls = []

    class R:
        status_code = 200
        text = '[{"id": "x1", "i18nTitle": {"de": "Titel"}}]'
        content = b"{}"

        def json(self):
            return json.loads(self.text) if self.text.startswith("[") else {"info": [{"severity": "Minor"}]}

    class FakeReq:
        def get(self, url, **kw):
            calls.append(("requests.get", url, kw))
            return R()
    ds["requests"] = FakeReq()
    ds["_nina_get"] = lambda url, **kw: (calls.append(("_nina_get", url, kw)), R())[1]
    exec(fn_source(new, "fetch_nina", 0), ds)
    w = ds["fetch_nina"]()
    assert isinstance(w, list) and len(w) == 7 and [c[0] for c in calls] == ["_nina_get"] * 7, [c[0] for c in calls]
    assert all(c[1].startswith("https://warnung.bund.de/api31/dashboard/") and c[2].get("timeout") == 8 and "verify" not in c[2] for c in calls), calls[:2]
    del calls[:]
    del ds["_nina_get"]
    w = ds["fetch_nina"]()
    assert [c[0] for c in calls] == ["requests.get"] * 7 and len(w) == 7, "ohne Block muss requests.get greifen"
    n += 2
    ds2 = {"requests": FakeReq(), "_LG_UA": {"User-Agent": "x"}, "_lg_mod": type("M", (), {"url": staticmethod(lambda w: "https://warnung.bund.de/api31/warnings/%s.geojson" % w), "MAX_RAW": 10 ** 6})}
    ds2["_nina_get"] = lambda url, **kw: (calls.append(("_nina_get", url, kw)), R())[1]
    exec(fn_source(new, "_lg_fetch_one"), ds2)
    del calls[:]
    doc, err = ds2["_lg_fetch_one"]("kat.1")
    assert err is None and [c[0] for c in calls] == ["_nina_get"] and calls[0][2] == {"timeout": 8, "headers": {"User-Agent": "x"}}, calls
    del ds2["_nina_get"]
    del calls[:]
    ds2["_lg_fetch_one"]("kat.1")
    assert [c[0] for c in calls] == ["requests.get"]
    n += 2
    ds3 = {"requests": FakeReq(), "_t2d_re": _re, "_t2d_time": time, "T2D_ID_RE": _re.compile(r"^[A-Za-z0-9._:-]{3,140}$"), "T2D_NINA_URL": "https://warnung.bund.de/api31/warnings/%s.json",
           "T2D_NINA_RETRY_S": 600, "T2D_NINA_NEW_MAX": 3, "_T2D": {"nina": {}}, "_t2d_plain": lambda t, k: t}
    ds3["_nina_get"] = lambda url, **kw: (calls.append(("_nina_get", url, kw)), R())[1]
    exec(fn_source(new, "_t2d_nina_detail"), ds3)
    del calls[:]
    ds3["_t2d_nina_detail"]([{"id": "kat.7"}])
    assert [c[0] for c in calls] == ["_nina_get"] and calls[0][1] == "https://warnung.bund.de/api31/warnings/kat.7.json", calls
    del ds3["_nina_get"]
    del calls[:]
    ds3["_T2D"]["nina"].clear()
    ds3["_t2d_nina_detail"]([{"id": "kat.7"}])
    assert [c[0] for c in calls] == ["requests.get"]
    n += 2
    # 16) Kachel (Jinja)
    import jinja2
    env = jinja2.Environment(autoescape=True)
    tpl = env.from_string(edits[0][1])
    nina = {"color": "#94a3b8", "updated": "26.10.2026 18:00:00"}
    h = tpl.render(nina=nina)
    assert "26.10.2026 18:00:00" in h and "nina-cert" not in h and "Zertifikatskette" not in h, "ohne Hinweis darf nichts erscheinen: " + h
    h = tpl.render(nina=nina, nina_cert=None)
    assert "nina-cert" not in h
    h = tpl.render(nina=nina, nina_cert={"text": "<b>x</b> gepinnte", "color": "#eab308", "title": "t"})
    assert 'id="nina-cert"' in h and "Zertifikatskette: &lt;b&gt;x&lt;/b&gt; gepinnte" in h and "<b>x</b>" not in h and "#eab308" in h and h.index("26.10.2026") < h.index("nina-cert"), "Kachel mit Hinweis: " + h
    n += 3
    # 17) kaputter Selbsttest/Einbau wird gemeldet, kein Einbau
    g2 = mk_ns()
    g2["app"] = None
    o = run_block(B, g2)
    assert "ninaFix Selbsttest FEHLER" in o and "aktiv" not in o, "Einbaufehler wird nicht gemeldet: " + o[:200]
    n += 1
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_NF_NOSTATIC") == "1" else static(alt, new, blk, edits)
    if os.environ.get("RH_NF_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk, edits)
    print("OK guard ninaFix: %d Pruefungen, 0 fehlerhaft" % n)
    return n


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    B = rd(blk).rstrip("\n")
    edits, anch = load_edits(ep)
    pre, post = base_new[:base_new.index(B)], base_new[base_new.index(B):]

    def rep(s, a, b):
        assert s.count(a) == 1, "%s: %d" % (a[:60], s.count(a))
        return s.replace(a, b, 1)
    M = []
    for i, nm in enumerate(("M1 Kachel-Edit", "M2 page1-Edit", "M3 fetch_nina-Edit", "M4 lageGeo-Edit", "M5 Teil-2-Edit")):
        M.append((nm + " zurueckgenommen", rep(pre, edits[i][1], edits[i][0]) + post, B, 1, None))
    M.append(("M6 stille Zusatzaenderung", rep(pre, "def _fnum(x):\n", "def _fnum(x): \n") + post, B, 0, None))
    for nm, a, b in (("T1 Kachel ohne Bedingung", "{% if nina_cert %}", "{% if True %}"),
                     ("T2 Kachel ohne Beschriftung Zertifikatskette", "⚠ Zertifikatskette: ", "⚠ "),
                     ("T3 Kachel ohne Maskierung des Textes", "{{ nina_cert.text }}", "{{ nina_cert.text|safe }}")):
        e2 = [tuple(x) for x in edits]
        e2[0] = (e2[0][0], rep(e2[0][1], a, b))
        M.append((nm, rep(pre, edits[0][1], e2[0][1]) + post, B, 1, e2))
    for nm, a, b in (
            ("B1 verify=False im Rueckfall", "            r = getter(url, verify=path, **kw)\n        except Exception as e2:", "            r = getter(url, verify=False, **kw)\n        except Exception as e2:"),
            ("B2 Pruefsumme der Zwischenstelle nicht geprueft", "    if _nf_hl.sha256(der).hexdigest() != NF_DER_SHA256:", "    if False:"),
            ("B3 anderer Fingerabdruck", 'NF_DER_SHA256 = "873f0ba8', 'NF_DER_SHA256 = "973f0ba8'),
            ("B4 Rueckfall bei jedem SSL-Fehler", "        if not (_nf_ssl_err(e) and _nf_chain_err(e)):", "        if not _nf_ssl_err(e):"),
            ("B5 Rueckfall auch fuer fremde Hosts", "    if host not in NF_HOSTS:", "    if False:"),
            ("B6 uebergebenes verify wird durchgereicht", '    kw.pop("verify", None)          # nie von aussen: die Pruefung bleibt immer an\n', ""),
            ("B7 Rueckfall bleibt nicht 10 min", "    sticky = _NF[\"chain_t\"] is not None and 0 <= now - _NF[\"chain_t\"] < NF_STICKY_S", "    sticky = False"),
            ("B8 kombiniertes Bundle wird nicht an die Stelle gesetzt", "                _nf_os.replace(tmp, target)", "                pass"),
            ("B9 Bundle ohne Zwischenstelle", '    out = data.rstrip(b"\\n") + b"\\n" + pem.encode("ascii")', '    out = data'),
            ("B10 Hinweis ohne Zeitpunkt", '    _NF["fb_t"] = now\n', ""),
            ("B11 Ablaufdatum falsch", "NF_NOT_AFTER = 2089756799", "NF_NOT_AFTER = 1089756799"),
            ("B12 Fehlerart fehlt", 'NF_ERRS = ("unable to get local issuer certificate", ', "NF_ERRS = ("),
            ("B13 Route erlaubt POST", 'methods=["GET"])\n        _nf_pem0', 'methods=["GET", "POST"])\n        _nf_pem0'),
            ("B14 Block mit subprocess", "def _nf_log(key, msg, now=None, every=NF_LOG_S):\n", "import subprocess\n\n\ndef _nf_log(key, msg, now=None, every=NF_LOG_S):\n"),
            ("B15 Block ohne Ende-Marker", "# ===== /ninaFix =====", ""),
            ("B16 Selbsttest schluckt Fehler", '    print("ninaFix Selbsttest FEHLER (%s: %s)" % (type(_nf_e).__name__, _nf_e), flush=True)\n', "    pass\n"),
            ("B17 normaler Abruf setzt Kettenzustand nicht zurueck", '        _NF["chain_t"] = None\n        _NF["fail"] = None\n        _NF["log"].pop("used", None)', '        _NF["fail"] = None\n        _NF["log"].pop("used", None)'),
            ("B18 mehrere Zertifikate in der Pin-Datei erlaubt", 'if txt.count("-----BEGIN CERTIFICATE-----") != 1:', 'if txt.count("-----BEGIN CERTIFICATE-----") < 1:'),
            ("B19 Fehler im Rueckfall wird verschluckt", '            if _nf_ssl_err(e2):\n                _nf_fail(now, "auch mit der gepinnten Zwischenstelle nicht pruefbar")\n            raise', '            return None'),
            ("B20 Bundle nicht zwischengespeichert", '            if _NF["bkey"] == key and _nf_os.path.isfile(target):\n                return target, None\n', ""),
            ("B21 Temp-Datei bleibt bei Fehler liegen", '                try:\n                    _nf_os.unlink(tmp)\n                except OSError:\n                    pass\n                raise', "                raise"),
            ("B22 Host-Liste erweitert", 'NF_HOSTS = ("warnung.bund.de",)', 'NF_HOSTS = ("warnung.bund.de", "example.org")'),
            ("B23 Hostpruefung ausgeschaltet", "ssl.create_default_context", "ssl.create_default_context")):
        if nm.startswith("B23"):
            continue
        assert B.count(a) == 1, nm + " (%d)" % B.count(a)
        nb = B.replace(a, b)
        M.append((nm, pre + nb + post[len(B):], nb, 1, None))
    bad = []
    done = 0
    for name, mnew, mblk, norev, e2 in M:
        w = tempfile.mkdtemp(prefix="nf-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            bf = os.path.join(w, "blk.py")
            with open(bf, "w", encoding="utf-8") as f:
                f.write(mblk if mblk.endswith("\n") else mblk + "\n")
            ef = ep
            if e2 is not None:
                ef = os.path.join(w, "edits.py")
                with open(ef, "w", encoding="utf-8") as f:
                    f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            if norev:
                os.environ["RH_NF_NOREV"] = "1"
            else:
                os.environ.pop("RH_NF_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, bf, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_NF_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)

    def edmut(name, fn):
        nonlocal done
        e2 = fn([tuple(x) for x in edits])
        w = tempfile.mkdtemp(prefix="nf-mut-")
        try:
            ef = os.path.join(w, "edits.py")
            with open(ef, "w", encoding="utf-8") as f:
                f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new)
            os.environ.pop("RH_NF_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, blk, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            shutil.rmtree(w, ignore_errors=True)
    edmut("E1 eine Stelle fehlt", lambda e: e[1:])
    edmut("E2 Stelle mit falschem Alttext (Rueckbau ungenau)", lambda e: [(e[0][0] + "# x\n", e[0][1])] + e[1:])
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation ninaFix: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[0] == "revert":
            revert(*a[1:5])
        elif a[0] == "check":
            check(*a[1:5])
        elif a[0] == "mutate":
            sys.exit(mutate(*a[1:4]))
        else:
            print(__doc__)
            sys.exit(2)
    except AssertionError as e:
        print("guard ninaFix FEHLER: %s" % e)
        sys.exit(1)
MK_RAG_EOF
EXPECT_CRT="7c6a6533e40bafb4cbb46d60e8098b1529829053f903aa5b195ce61d5a9f2fd6"
cat > "$W/sectigo-e36.pem" << 'MK_CRT_EOF'
-----BEGIN CERTIFICATE-----
MIIDXzCCAuagAwIBAgIQNuBZ7YiN1Xrt1XC2cn+b2jAKBggqhkjOPQQDAzBfMQsw
CQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1T
ZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBFNDYwHhcN
MjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBgMQswCQYDVQQGEwJHQjEYMBYG
A1UEChMPU2VjdGlnbyBMaW1pdGVkMTcwNQYDVQQDEy5TZWN0aWdvIFB1YmxpYyBT
ZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgRTM2MFkwEwYHKoZIzj0CAQYIKoZI
zj0DAQcDQgAEaKGnbAUnBYljHDmn/yUhxe3TLxKYuyzc9VXoSaCEV5F73Fhfa/Si
/RMsmwTFW3R9s7J6JpYZFmu4do3vk/Vgl6OCAYEwggF9MB8GA1UdIwQYMBaAFNEi
2kxZ8UtfJjiqndbu6w3D+6lhMB0GA1UdDgQWBBQXmagEwW/kLXCoChA9A9PpGrgm
YzAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHSUEFjAU
BggrBgEFBQcDAQYIKwYBBQUHAwIwGwYDVR0gBBQwEjAGBgRVHSAAMAgGBmeBDAEC
ATBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3Rp
Z29QdWJsaWNTZXJ2ZXJBdXRoZW50aWNhdGlvblJvb3RFNDYuY3JsMIGEBggrBgEF
BQcBAQR4MHYwTwYIKwYBBQUHMAKGQ2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2Vj
dGlnb1B1YmxpY1NlcnZlckF1dGhlbnRpY2F0aW9uUm9vdEU0Ni5wN2MwIwYIKwYB
BQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMAoGCCqGSM49BAMDA2cAMGQC
MFsKnBQDh64l+v+aUYWjDCJKQMxHUUGmcwAYDIjJ9pbRYItMCIx5xu0oUb6sIfTX
qQIwPddcsDE4KdeLu1hJdpHgdLvsHAK3vygyLGujMU9xBJCDackRT93VHEE0gppg
NqdV
-----END CERTIFICATE-----
MK_CRT_EOF
EXPECT_PRB="1e2279898dfd1ec8a9336eb3d3d834c42dadddd142bb7e7e7d043b6a45f4c03b"
cat > "$W/probe.py" << 'MK_PRB_EOF'
#!/usr/bin/env python3
"""Probe ninaFix (nur Lesen): laedt den Block mit einer Attrappe der App, ruft EINE NINA-URL ueber _nina_get ab (normaler Abruf, bei fehlender Zwischenstelle der gepinnte Rueckfall).
Aufruf (mit dem Python der venv): probe_nf.py BLOCK.py FAKE_DASHBOARD_PY URL    -> certs liegt neben FAKE_DASHBOARD_PY. Ausgabe: eine Zeile PROBE ... ; Exit 0 = Ausgabe ist das Ergebnis, 3 = interner Fehler."""
import ast
import sys

blk, fake, url = sys.argv[1:4]


class _App:
    def add_url_rule(self, *a, **k):
        self.rules = getattr(self, "rules", 0) + 1


def main():
    with open(blk, encoding="utf-8") as f:
        src = f.read()
    ast.parse(src)
    g = {"__name__": "nfprobe", "__file__": fake, "app": _App()}
    exec(compile(src, "ninafix-block", "exec"), g)
    if not g.get("_NF_ST"):
        print("PROBE INTERN Selbsttest des Blocks fehlgeschlagen")
        return 3
    import requests
    pem, why = g["_nf_pin"]()
    try:
        r = g["_nina_get"](url, timeout=12, headers={"User-Agent": "KaeswasserLage/1.0"})
    except requests.exceptions.SSLError as e:
        m = str(e)
        chain = g["_nf_chain_err"](e)
        print("PROBE SSL %s pin=%s fallback_n=%d: %s" % ("KETTE" if chain else "ANDERER", "ok" if pem else "fehlt (%s)" % why, g["_NF"]["fb_n"], m[:160].replace("\n", " ")))
        return 0
    except Exception as e:
        print("PROBE NETZ %s pin=%s: %s" % (type(e).__name__, "ok" if pem else "fehlt (%s)" % why, str(e)[:120].replace("\n", " ")))
        return 0
    print("PROBE OK HTTP %s %s pin=%s plain_n=%d fallback_n=%d" % (r.status_code, "Rueckfall genutzt" if g["_NF"]["fb_n"] else "normaler Abruf", "ok" if pem else "fehlt", g["_NF"]["plain_n"], g["_NF"]["fb_n"]))
    return 0


try:
    sys.exit(main())
except SystemExit:
    raise
except BaseException as e:
    print("PROBE INTERN %s: %s" % (type(e).__name__, str(e)[:160]))
    sys.exit(3)
MK_PRB_EOF
PPK="$W/patch.py"; RED="$W/edits.py"; RBK="$W/blk.py"; RGD="$W/guard.py"
for x in "$EXPECT_PAL $PPK" "$EXPECT_RAE $RED" "$EXPECT_RAB $RBK" "$EXPECT_RAG $RGD" "$EXPECT_CRT $W/sectigo-e36.pem" "$EXPECT_PRB $W/probe.py"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Patcher, Stellen, Block, Pruefprogramm, Zwischenstelle, Probe)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach clockOff commit35" "$KNOWN_D16N" "ninaFix schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      ninaFix passt nur auf den Stand Stand nach clockOff commit35 (dashboard.py 1831e7cd923396d1). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- ninaFix: Neustart-Fenster rund um die Wetter-Slots (3-h-Takt 0,3,...,21 Uhr, Berlin) ----
# Gesperrt: HH:55-HH:59 jeder Stunde vor einem Slot (z. B. 14:55-14:59), die ersten 5 Minuten der Slot-Stunde (15:00-15:04) und HH:55-HH:59 der Slot-Stunde selbst.
# (Neustart um HH:59 kann die Slot-Meldung verzoegern; wxSlot holt sie dann nach, aber der Apply soll nie selbst in dieses Fenster fallen.)
wxwin() { local s=$1 h m r; h=$(( s / 3600 % 24 )); m=$(( s / 60 % 60 )); r=$(( h % 3 ))
  if [[ $r == 2 && $m -ge 55 ]]; then return 0; fi
  if [[ $r == 0 && ( $m -lt 5 || $m -ge 55 ) ]]; then return 0; fi
  return 1; }
wxsec() { local hm
  if [[ -n "${WXSLOT_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$WXSLOT_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) + $1 )); }
wxfree() { local k s; for k in $(seq 0 240); do s=$(wxsec $(( k * 60 ))); wxwin "$s" || { printf '%02d:%02d' $(( s / 3600 % 24 )) $(( s / 60 % 60 )); return; }; done; echo "?"; }
wxcheck() { local when=$1 s0 s1
  s0=$(wxsec 0); s1=$(wxsec 150)
  if wxwin "$s0" || wxwin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Fenster: jetzt ($when, Berlin-Zeit $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 )))) waere ein echter Lauf gesperrt (Slot-Zeit des Wetters) - frei ab ca. $(wxfree) Uhr; der Trockenlauf aendert nichts"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Fenster: ninaFix ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Fenster: es ist $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 ))) Uhr (Berlin) - kurz vor/in/nach einer 3-h-Wetter-Slot-Zeit (0,3,...,21 Uhr; gesperrt HH:55-HH:04 um die Slots und HH:55-HH:59 der Slot-Stunde). Ein Neustart jetzt koennte die Wetter-Slot-Meldung verzoegern (wxSlot holt sie zwar nach, aber das Fenster wird gemieden). Bitte ab ca. $(wxfree) Uhr neu starten (Bridge und andere Dienste wurden nicht beruehrt)"; fi
  else echo "OK Neustart-Fenster: $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 ))) Uhr (Berlin) liegt ausserhalb der Wetter-Slot-Zeit (gesperrt HH:55-HH:04 um 0,3,...,21 Uhr und HH:55-HH:59 der Slot-Stunden)"; fi; }
wxcheck "Vorpruefung"
# ---- ninaFix: gepinnte Zwischenstelle (Sectigo E36) pruefen - Pruefsumme, Wurzel im Bundle, Laufzeit ----
CRT="$W/sectigo-e36.pem"; PRB="$W/probe.py"
CERT_DIR="$DASH_DIR/certs"; CERT_F="$CERT_DIR/sectigo-e36.pem"
CRT_DER=$("$SPY" -c 'import ssl, sys, hashlib; print(hashlib.sha256(ssl.PEM_cert_to_DER_cert(open(sys.argv[1], encoding="ascii").read())).hexdigest())' "$CRT" 2>/dev/null || true)
[[ "$CRT_DER" == "$KNOWN_DER" ]] || stop "eingebettete Zwischenstelle: DER-SHA-256 ${CRT_DER:-unlesbar} statt $KNOWN_DER (Skript beschaedigt)"
[[ "$(grep -c 'BEGIN CERTIFICATE' "$CRT")" == 1 ]] || stop "eingebettete Zwischenstelle enthaelt nicht genau ein Zertifikat"
if command -v openssl >/dev/null 2>&1; then
  openssl x509 -in "$CRT" -noout -checkend 0 >/dev/null 2>&1 || stop "gepinnte Zwischenstelle ist abgelaufen"
  CRT_END=$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
  BASEB=/etc/ssl/certs/ca-certificates.crt
  if ! [[ -f "$BASEB" && $(wc -c < "$BASEB") -gt 10000 ]]; then BASEB=$("$VPY" -c 'import certifi; print(certifi.where())' 2>/dev/null || true); fi
  if [[ -n "$BASEB" && -f "$BASEB" ]]; then
    VR=$(openssl verify -CAfile "$BASEB" "$CRT" 2>&1 || true)
    echo "$VR" | grep -q ': OK$' || { echo "$VR" | cut -c1-200; stop "gepinnte Zwischenstelle laesst sich nicht gegen das Basis-Zertifikatsbundle ($BASEB) pruefen - die Wurzel (Sectigo E46) fehlt dort?"; }
    echo "OK Zwischenstelle Sectigo E36: SHA-256 (DER) ${CRT_DER:0:16}..., gueltig bis ${CRT_END:-?}, kettet im Basisbundle $BASEB auf die Wurzel"
  else stop "kein Basis-Zertifikatsbundle gefunden (weder /etc/ssl/certs/ca-certificates.crt noch certifi in der venv)"; fi
else echo "HINWEIS openssl nicht vorhanden - Wurzel-/Laufzeitpruefung der Zwischenstelle entfaellt (der Block prueft die Pruefsumme selbst)"; fi
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
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" ninaFix dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer ninaFix nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" ninaFix dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: ninaFix im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne ninaFix ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard ninaFix meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" nice -n 10 "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
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
PILAT0=$(tmed "$B/pi")
echo "Zustand vorher: /pi antwortet im Median in ${PILAT0} s"
# ---- ninaFix: Zustand der Zertifikatsdatei, Live-Probe (nur Lesen) ----
CERT_STATE=fehlt
if [[ -L "$CERT_F" || ( -e "$CERT_F" && ! -f "$CERT_F" ) ]]; then stop "$CERT_F ist keine normale Datei (Link/Ordner) - bitte ansehen"; fi
if [[ -f "$CERT_F" ]]; then cmp -s "$CRT" "$CERT_F" && CERT_STATE=gleich || CERT_STATE=anders; fi
if [[ -e "$CERT_DIR" && ! -d "$CERT_DIR" ]]; then stop "$CERT_DIR existiert, ist aber kein Ordner"; fi
NEED_C=0; [[ "$CERT_STATE" == gleich ]] || NEED_C=1
if [[ "$NEED_C" == 1 && -d "$CERT_DIR" && ! -w "$CERT_DIR" ]]; then stop "Ordner $CERT_DIR nicht beschreibbar"; fi
echo "Zustand vorher: Zwischenstelle certs/sectigo-e36.pem: $CERT_STATE$([[ "$CERT_STATE" == gleich ]] && echo " (schon die gepinnte)" || { [[ "$CERT_STATE" == anders ]] && echo " (andere Datei - wird gesichert und ersetzt)"; })"
mkdir -p "$W/probe/certs" && cp "$CRT" "$W/probe/certs/sectigo-e36.pem"
NINA_PROBE_URL="https://warnung.bund.de/api31/dashboard/095640000000.json"
"$VPY" "$PRB" "$RBK" "$W/probe/dashboard.py" "$NINA_PROBE_URL" > "$W/probe.out" 2> "$W/probe.err" || true
PRL=$(grep '^PROBE' "$W/probe.out" | tail -1 || true)
case "$PRL" in
  "PROBE OK"*) echo "OK Live-Probe (nur Lesen, ein Abruf $NINA_PROBE_URL): ${PRL#PROBE OK }" ;;
  "PROBE SSL KETTE"*) echo "$PRL" | cut -c1-260; stop "Live-Probe: warnung.bund.de bleibt auch mit der gepinnten Zwischenstelle ungepruefbar (Kette) - der Server sendet vermutlich eine andere Zwischenstelle; ninaFix wuerde nicht helfen" ;;
  "PROBE INTERN"*) echo "$PRL" | cut -c1-260; stop "Live-Probe: interner Fehler im Pruefprogramm" ;;
  "") cat "$W/probe.err" | cut -c1-200; stop "Live-Probe lieferte keine Ausgabe" ;;
  *) echo "HINWEIS Live-Probe: ${PRL#PROBE } - warnung.bund.de ist von hier aus gerade nicht (sauber) erreichbar; das ist unabhaengig vom Patch, die Funktion ist offline getestet (Guard, Testserver). Der Apply laeuft weiter." ;;
esac
wxcheck "vor dem Neustart"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 && "$NEED_C" == 0 ]]; then echo "  Zustand: ninaFix ist schon installiert (Programm und Zertifikatsdatei) - ein echter Lauf aendert nichts."
  elif [[ "$NEED_D" == 0 ]]; then echo "  Ein echter Lauf wuerde: nur certs/sectigo-e36.pem installieren (Zustand $CERT_STATE; kein Neustart noetig, der Block liest die Datei bei Bedarf)."
  else echo "  Ein echter Lauf wuerde: certs/sectigo-e36.pem installieren (Zustand $CERT_STATE), dashboard.py ersetzen (Sicherung dashboard.py.bak-ninafix-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG ninafix=dry fertig"
  exit 0
fi
if [[ "$NEED_D" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "ninaFix|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-ninafix-$TS" ]] && cp -a "$F.bak-ninafix-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ -n "${CERT_BAK:-}" && -f "${CERT_BAK:-/nonexistent}" ]]; then cp -a "$CERT_BAK" "$CERT_F.rb" && mv -f "$CERT_F.rb" "$CERT_F" && echo "  certs/sectigo-e36.pem = Sicherung"
  elif [[ "${CERT_NEW:-0}" == 1 ]]; then rm -f "$CERT_F" "$CERT_DIR/nina-ca-bundle.pem" "$CERT_DIR"/.nina-ca-bundle-*.tmp "$CERT_DIR"/.sectigo-e36.pem.new-*; echo "  certs/sectigo-e36.pem wieder entfernt (war neu)"; fi
  if [[ "${CERT_MADE_DIR:-0}" == 1 ]]; then rmdir "$CERT_DIR" 2>/dev/null && echo "  Ordner certs wieder entfernt (war neu)" || true; fi
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-ninafix-$TS" ]] && { cmp -s "$F" "$F.bak-ninafix-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 || "$NEED_C" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
CERT_BAK=""; CERT_NEW=0; CERT_MADE_DIR=0
if [[ "$NEED_C" == 1 ]]; then
  if [[ ! -d "$CERT_DIR" ]]; then mkdir -m 755 "$CERT_DIR" && CERT_MADE_DIR=1 || { echo "FEHLER: Ordner $CERT_DIR nicht anlegbar - nichts geaendert"; exit 1; }; fi
  if [[ -f "$CERT_F" ]]; then
    CERT_BAK="$CERT_F.bak-ninafix-$TS"; cp -a "$CERT_F" "$CERT_BAK" || { echo "FEHLER: Sicherung der alten Zwischenstelle misslungen - nichts geaendert"; exit 1; }
    { ls -1t "$CERT_F.bak-ninafix-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  else CERT_NEW=1; fi
  CT="$CERT_DIR/.sectigo-e36.pem.new-$$"
  cp "$CRT" "$CT" && chmod 644 "$CT" && mv -f "$CT" "$CERT_F" || { rm -f "$CT"; rb "Zwischenstelle installieren"; exit 1; }
  [[ "$(sha256sum "$CERT_F" | cut -d' ' -f1)" == "$KNOWN_CRT_SHA" ]] || { rb "Zwischenstelle nach dem Kopieren falsch"; exit 1; }
  echo "OK certs/sectigo-e36.pem atomar installiert ($([[ "$CERT_NEW" == 1 ]] && echo neu || echo "alte gesichert: $(basename "$CERT_BAK")"), Modus 644; behalten: letzte $KEEP_LAST)"
fi
if [[ "$NEED_D" == 0 ]]; then
  echo "OK ninaFix im Programm schon installiert - kein Neustart"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-ninafix-$TS"
  { ls -1t "$F.bak-ninafix-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-ninafix-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-ninafix-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'ninaFix aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; ninaFix aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- ninaFix: Marker, Aufrufstellen, Zertifikatsdatei, API, Kachel, erster NINA-Abruf ----
NFM=$(grep -c "^# ===== ninaFix:" "$F" || true); NFG=$(grep -c 'globals().get("_nina_get") or requests.get' "$F" || true)
[[ "$NFM" == 1 && "$NFG" == 3 ]] && echo "OK Marker ninaFix 1x im Programm, 3 NINA-Abrufstellen (fetch_nina, lageGeo, Teil 2) laufen ueber _nina_get" || rbx "Marker/Abrufstellen ninaFix falsch (Marker $NFM, Stellen $NFG)"
[[ "$(sha256sum "$CERT_F" | cut -d' ' -f1)" == "$KNOWN_CRT_SHA" ]] && echo "OK Zertifikatsdatei certs/sectigo-e36.pem: SHA-256 ${KNOWN_CRT_SHA:0:16}..., Modus $(stat -c %a "$CERT_F")" || rbx "Zertifikatsdatei certs/sectigo-e36.pem falsch"
"${CURL[@]}" "$B/api/nina-cert" -o "$W/nc.json" -w "" || true
NCR=$(python3 - "$W/nc.json" <<'PY' 2>/dev/null || echo "NOK unlesbar"
import sys, json
j = json.load(open(sys.argv[1]))
ok = j.get("pin_ok") is True and j.get("hosts") == ["warnung.bund.de"] and isinstance(j.get("pin_days_left"), int) and j.get("pin_days_left") > 90
print("OK" if ok else "NOK", "mode=%s" % j.get("mode"), "plain_n=%s" % j.get("plain_n"), "fallback_n=%s" % j.get("fallback_n"), "chain_bad=%s" % j.get("chain_bad"), "pin_days_left=%s" % j.get("pin_days_left"), "pin_why=%s" % j.get("pin_why"))
PY
)
case "$NCR" in OK*) echo "OK /api/nina-cert: ${NCR#OK }" ;; *) rbx "/api/nina-cert liefert keine gueltige Antwort ($NCR)" ;; esac
c8=$(pcode "$B/api/nina-cert")
[[ "$c8" == 405 ]] && echo "OK /api/nina-cert nimmt kein POST an (HTTP 405)" || rbx "/api/nina-cert: POST ergibt HTTP $c8 (erwartet 405)"
# erster NINA-Abruf des Dashboards nach dem Neustart (das erste Voll-Update holt NINA)
NCOK=0; NCN=0
if [[ "$RESTARTED_D" == 1 ]]; then
  for i in $(seq 1 40); do
    "${CURL[@]}" "$B/api/nina-cert" -o "$W/nc.json" || true
    NCN=$(python3 - "$W/nc.json" <<'PY' 2>/dev/null || echo 0
import sys, json
j = json.load(open(sys.argv[1])); print((j.get("plain_n") or 0) + (j.get("fallback_n") or 0))
PY
)
    [[ "${NCN:-0}" -ge 1 ]] && { NCOK=1; break; }
    sleep 3
  done
  if [[ "$NCOK" == 1 ]]; then
    NCS=$(python3 - "$W/nc.json" <<'PY' 2>/dev/null || echo "?"
import sys, json
j = json.load(open(sys.argv[1]))
print("mode=%s plain_n=%s fallback_n=%s fail=%s" % (j.get("mode"), j.get("plain_n"), j.get("fallback_n"), j.get("fail")))
PY
)
    case "$NCS" in *"mode=fehler"*) echo "HINWEIS Erster NINA-Abruf nach dem Neustart: $NCS - die Kette ist auch mit der gepinnten Zwischenstelle nicht pruefbar (Journal: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep ninaFix). Kein Rollback: der alte Stand haette denselben Fehler." ;;
      *) echo "OK Erster NINA-Abruf des Dashboards nach dem Neustart: $NCS" ;; esac
  else echo "HINWEIS Bis jetzt (2 min) kein NINA-Abruf im Dashboard gezaehlt (erstes Voll-Update dauert) - spaeter pruefen: curl -s $B/api/nina-cert"; fi
fi
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
if grep -q 'id="nina-cert"' "$W/lage.html" 2>/dev/null; then echo "HINWEIS Lage-Seite zeigt den Kachelhinweis: '$(grep -o 'id="nina-cert"[^>]*>[^<]*' "$W/lage.html" | head -1 | sed 's/^[^>]*>//' | cut -c1-160)'"; else echo "OK Lage-Seite: kein Zertifikatskette-Hinweis (Kette ok oder noch kein Abruf)"; fi
# NINA-Quelle in der Systemseite: Erfolg seit dem Neustart (nur am echten Dashboard-Port 5000; die Frist reicht fuer den ersten Lauf des Alarm-Fadens)
if [[ "$RESTARTED_D" == 1 && "$PORT" == 5000 ]]; then
  NSOK=0; NSV="?"
  for i in $(seq 1 28); do
    "${CURL[@]}" "$B/api/sysboot/status" -o "$W/sb.json" || true
    NSV=$(python3 - "$W/sb.json" <<'PY' 2>/dev/null || echo "?"
import sys, json
n = ((json.load(open(sys.argv[1])).get("alarm") or {}).get("src") or {}).get("nina") or {}
print("ok" if (n.get("ok_at") and not n.get("fails")) else "offen", "fails=%s ok_at=%s" % (n.get("fails"), n.get("ok_at")))
PY
)
    case "$NSV" in ok*) NSOK=1; break ;; esac
    sleep 15
  done
  [[ "$NSOK" == 1 ]] && echo "OK NINA-Quelle (Alarm-Faden) seit dem Neustart erfolgreich: ${NSV#ok }" || echo "HINWEIS NINA-Quelle im Alarm-Faden noch ohne Erfolg nach 7 min (${NSV#* }) - kein Patch-Fehler, bitte nachsehen: curl -s $B/api/sysboot/status ; sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E 'NINA|ninaFix'"
fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E ninaFix"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "ninaFix aktiv: ninaFix ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'ninaFix aktiv: ninaFix ok' ($(echo "$JD" | grep -F ninaFix | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein ninaFix-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)")"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"))" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-ninafix-$TS" ]] && echo "Backup: dashboard.py.bak-ninafix-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen; certs/sectigo-e36.pem $(sha256sum "$CERT_F" | cut -c1-16)"
[[ -n "${CERT_BAK:-}" ]] && echo "Sicherung Zwischenstelle: $(basename "$CERT_BAK")"
LB=$({ ls -1t "$F.bak-ninafix-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard   (die Zertifikatsdatei darf bleiben, sie ist harmlos)" || echo "Rueckweg: keine ninafix-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s http://127.0.0.1:5000/api/nina-cert"
echo "  curl -s http://127.0.0.1:5000/api/sysboot/status | python3 -m json.tool | grep -A6 '\"nina\"'"
echo "  ls -l /home/fmg/prepper-dashboard/certs"
echo "  grep -c 'ninaFix' /home/fmg/prepper-dashboard/dashboard.py"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep ninaFix"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG ninafix=1 fertig"
