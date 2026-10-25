#!/bin/bash
set -eEuo pipefail
# secHard (commit24): SEC-09 + SEC-10 + SEC-11 des Audits. Aendert NUR health_check.py (keine Shell mehr, config.py wird nicht mehr ausgefuehrt) und legt neu an:
#   lage_xml.py (gehaertetes XML-Parsen, defusedxml wenn vorhanden, sonst alter Parser mit Groessenlimit und ehrlicher Meldung - NICHT in dashboard.py eingebunden),
#   tools/lage_reqs.py (lesendes Werkzeug: Fremdpakete gegen das venv, requirements-Vorlage, optional Hashes von PyPI), requirements.txt.vorlage (Platzhalter, KEINE benutzbare requirements.txt).
# Es wird NICHTS installiert (kein pip, kein apt), kein Dienst neu gestartet, kein sudo. dashboard.py, Bridges, database.py bleiben unberuehrt.
# Basis streng (sha16): health_check.py cc3949f1896ebbf3 (oder schon die neue Fassung = idempotent). Anderes = STOP mit Diff, nichts geaendert.
# Pruefungen vor dem Installieren: Guard + Mutationstest, Selbsttests, Vergleich alt/neu mit gefaelschten Programmen UND auf dem echten System (nur lesend: df, meminfo, vcgencmd, chronyc, systemctl is-active, apt list, MESHTASTIC_HOST).
# Sicherungen: health_check.py.bak-sechard-ZEIT (letzte 3) und von jeder ersetzten Datei. Option "trocken": nur pruefen, nichts aendern.
COMMIT_ARG="${1:-unbekannt}"
OPT="${2:-}"
NAME=sechard
DASH_DIR="/home/fmg/prepper-dashboard"
SPY=/usr/bin/python3
if [[ "${SYSTEM_TEST:-}" == 1 ]]; then DASH_DIR="${SY_DASH:?}"; fi    # nur fuer den Sandbox-Test dieses Skripts
VPY="$DASH_DIR/venv/bin/python"
HCF="$DASH_DIR/health_check.py"
XMLF="$DASH_DIR/lage_xml.py"
TOOLD="$DASH_DIR/tools"
REQF="$TOOLD/lage_reqs.py"
VORF="$DASH_DIR/requirements.txt.vorlage"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sechard-apply
KEEP_LAST=3
KNOWN_HC16="cc3949f1896ebbf3"
NEW_HC16="5a0156ff02d5960c"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
echo "=== secHard apply ($COMMIT_ARG)${OPT:+ [$OPT]}: health_check.py ohne Shell, lage_xml.py, tools/lage_reqs.py, requirements.txt.vorlage, Dashboard-Port $PORT ==="
umask 077
rm -rf "$W" && mkdir -p "$W/base" "$W/sbx"
EXPECT_HC="5a0156ff02d5960c86b9f478de0f948c42a823f4809b9da7e550bc37f2657fc4"
cat > "$W/health_check.py" << 'SEC_HC_EOF'
#!/usr/bin/env python3
"""Health Report → health_status.json (nie systemctl restart). /* health3h */ /* sysBoot */

secHard (SEC-09): keine Shell mehr (Argumentlisten, Auswertung der Pipes in Python), config.py wird nicht mehr ausgefuehrt (ast.literal_eval).
Die Pruefpunkte, Schwellen und Texte sind unveraendert. /* secHard */

sysBoot: laeuft der Dienst prepper-dashboard noch keine 10 min (z. B. direkt nach dem Booten), wartet der Check,
bis er 10 min alt ist (nur so lange, wie die eigene Einheit erlaubt); reicht das nicht, bleibt der letzte Bericht stehen
(kein falsches PROBLEM 12/27). Seiten mit 15 s Zeitlimit, Fehlschlaege einmal nach 20 s nachgeprueft."""
import ast
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
import pathlib
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
OUT = BASE / "health_status.json"
LOG = BASE / "health_check.log"
# Nav-Seiten (ohne API / Scanner / Decoder)
PAGES = [
    "/",
    "/energie",
    "/lokale-energie",
    "/speicher",
    "/umwelt",
    "/luft",
    "/pegel",
    "/adsb",
    "/zuhause",
    "/mesh",
    "/mesh2",
    "/news",
    "/funk",
    "/pi",
    "/medizin",
]

DASH_MIN_AGE_S = 600       # sysBoot
PAGE_TIMEOUT_S = 15        # sysBoot (vorher 8 s)
RETRY_PAUSE_S = 20         # sysBoot


def dash_age_s():
    """Sekunden seit Start von prepper-dashboard (None = unbekannt/inaktiv). # sysBoot"""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "ActiveEnterTimestampMonotonic", "-p", "ActiveState", "prepper-dashboard"],
                           capture_output=True, text=True, timeout=20)
        kv = dict(x.split("=", 1) for x in (p.stdout or "").splitlines() if "=" in x)
        if kv.get("ActiveState") != "active":
            return None
        us = int(kv.get("ActiveEnterTimestampMonotonic") or "0")
        if us <= 0:
            return None
        with open("/proc/uptime") as f:
            return max(0.0, float(f.read().split()[0]) - us / 1e6)
    except Exception:
        return None


def own_budget_s():
    """Wie lange darf diese Einheit laufen? (TimeoutStartUSec von prepper-health.service; infinity/unbekannt -> 900 s) # sysBoot"""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "TimeoutStartUSec", "--value", "prepper-health.service"],
                           capture_output=True, text=True, timeout=20)
        v = (p.stdout or "").strip()
        if not v or v == "infinity" or v == "0":
            return 900.0
        tot = 0.0
        for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*(min|ms|us|h|s)", v):
            tot += float(n) * {"h": 3600, "min": 60, "s": 1, "ms": 0.001, "us": 1e-6}[u]
        return tot if tot > 0 else 900.0
    except Exception:
        return 900.0


def wait_plan(age, budget):
    """-> (warten_s, ausfuehren). age None = Dienst nicht aktiv -> sofort pruefen (Fehler sind dann echt). # sysBoot"""
    if age is None or age >= DASH_MIN_AGE_S:
        return 0.0, True
    need = DASH_MIN_AGE_S - age + 5
    if need <= budget - 90:
        return need, True
    return 0.0, False


def fetch_page(p):
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:5000{p}", timeout=PAGE_TIMEOUT_S)
        return r.status
    except Exception:
        return 0


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")

def log(msg):
    line = f"[{now_str()}] {msg}"
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
        lines = LOG.read_text().splitlines()
        if len(lines) > 500:
            LOG.write_text("\n".join(lines[-350:]) + "\n")
    except Exception:
        pass

def run(cmd, timeout=40, cwd=None):
    """secHard (SEC-09): Argumentliste statt Shell. cmd MUSS eine Liste von Texten sein (kein shell=True, keine Pipes).
    -> (returncode, stdout, stderr), jeweils gekuerzt; Fehler/Zeitlimit -> (1, "", Text) wie bisher."""
    if not isinstance(cmd, (list, tuple)) or not cmd or not all(isinstance(x, str) for x in cmd):
        return 1, "", "run: Argumentliste erwartet"
    try:
        p = subprocess.run(
            list(cmd), capture_output=True, text=True, timeout=timeout, cwd=cwd
        )
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 1, "", str(e)

def disk_used_text(path="/"):
    """Spalte 5 der zweiten Zeile von df -P (z. B. 42%). Frueher: df -P / | awk NR==2{print $5}. Fehler -> ''."""
    rc, out, _ = run(["df", "-P", path])
    lines = out.splitlines()
    if len(lines) >= 2:
        f = lines[1].split()
        if len(f) >= 5:
            return f[4]
    return ""

def mem_available_text(path="/proc/meminfo"):
    """MemAvailable in kB als Ganzzahl-Text. Frueher: awk /MemAvailable/ printf %d $2. Fehler -> ''."""
    try:
        with open(path) as f:
            for line in f:
                if "MemAvailable" in line:
                    return str(int(float(line.split()[1])))
    except Exception:
        pass
    return ""

def temp_text():
    """Ausgabe von vcgencmd measure_temp ohne die Zeichen t e m p = ' C. Frueher: ... | tr -d "temp='C". Fehler -> ''."""
    rc, out, _ = run(["vcgencmd", "measure_temp"])
    return "".join(ch for ch in out if ch not in "temp='C").strip()

def chrony_text():
    """Die ersten 6 Zeilen von chronyc tracking. Frueher: chronyc tracking | head -6 (Rueckgabewert war der von head, daher nur der Text zaehlt)."""
    rc, out, _ = run(["chronyc", "tracking"])
    return "\n".join(out.splitlines()[:6]).strip()

def apt_upgradable_text():
    """Anzahl Zeilen von apt list --upgradable, die nicht mit Auflistung beginnen (als Text). Frueher: ... | grep -vc ^Auflistung || true.
    Zeitlimit/Fehler -> '' (Anzeige n/a), apt nicht vorhanden -> '0' wie bisher."""
    try:
        p = subprocess.run(["apt", "list", "--upgradable"], capture_output=True, text=True, errors="replace", timeout=40)
    except FileNotFoundError:
        return "0"
    except Exception:
        return ""
    return str(sum(1 for ln in (p.stdout or "").splitlines() if not ln.startswith("Auflistung")))

DEFAULT_MESH_HOST = "192.168.178.141"
_HOST_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9._-]{0,251}[A-Za-z0-9])?|[0-9A-Fa-f:]{2,45})$")

def host_ok(h):
    """Nur Hostname/IPv4/IPv6-Text, nie mit - am Anfang (keine Option fuer nc)."""
    return isinstance(h, str) and bool(_HOST_RE.match(h)) and not h.startswith("-")

def config_text_value(name, path=None):
    """secHard (SEC-09): einen einfachen Text (str) aus config.py lesen OHNE die Datei auszufuehren (ast.parse + literal_eval,
    nur oberste Ebene, die letzte Zuweisung gilt wie bei exec). Kein Text/keine Zuweisung -> None."""
    src = (path or (BASE / "config.py")).read_text(encoding="utf-8")
    val = None
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            try:
                val = ast.literal_eval(node.value)
            except Exception:
                val = None
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name and node.value is not None:
            try:
                val = ast.literal_eval(node.value)
            except Exception:
                val = None
    return val if isinstance(val, str) else None

def item(id_, ok, msg):
    return {"id": id_, "ok": bool(ok), "msg": str(msg)[:120]}

def mesh_host(path=None):
    try:
        h = config_text_value("MESHTASTIC_HOST", path)
        if h is None:
            return DEFAULT_MESH_HOST
        if not host_ok(h):
            log("MESHTASTIC_HOST in config.py ist kein gueltiger Hostname/IP-Text - Standardwert wird geprueft")
            return DEFAULT_MESH_HOST
        return h
    except Exception:
        return DEFAULT_MESH_HOST

def main():
    items = []
    try:
        age = dash_age_s()
        w, go = wait_plan(age, own_budget_s())
        if not go:
            log("uebersprungen: Dashboard erst %d s alt, Einheit darf nicht lange genug warten - letzter Bericht bleibt" % int(age or 0))
            return 0
        if w > 0:
            log("warte %d s: Dashboard erst %d s alt (Start laeuft)" % (int(w), int(age or 0)))
            time.sleep(w)
    except Exception as e:
        log(f"Startpruefung: {e}")
    try:
        rc, _, err = run(
            [str(BASE / "venv" / "bin" / "python"), "-m", "py_compile", "dashboard.py"], cwd=str(BASE)
        )
        items.append(
            item("compile", rc == 0, "Syntax OK" if rc == 0 else (err or "FAIL")[:80])
        )

        for svc in ("prepper-dashboard", "kiwix", "chrony"):
            rc, out, _ = run(["systemctl", "is-active", svc])
            items.append(item(f"svc_{svc}", rc == 0 and out == "active", out or "inactive"))

        codes = {p: fetch_page(p) for p in PAGES}
        bad = [p for p in PAGES if codes[p] != 200]
        if bad:
            time.sleep(RETRY_PAUSE_S)
            for p in bad:
                codes[p] = fetch_page(p)
            log("Seiten nachgeprueft: %d/%d jetzt ok" % (sum(1 for p in bad if codes[p] == 200), len(bad)))
        for p in PAGES:
            code = codes[p]
            items.append(item(f"page_{p}", code == 200, str(code)))

        try:
            code = urllib.request.urlopen("http://127.0.0.1:8080/", timeout=4).status
            k_ok = code == 200
        except Exception:
            k_ok, code = False, 0
        items.append(item("kiwix", k_ok, str(code)))

        host = mesh_host()
        rc, _, _ = run(["nc", "-z", "-w2", host, "4403"])
        items.append(item("mesh", rc == 0, f"{host}:4403"))

        out = disk_used_text("/")
        try:
            pct = int(out.replace("%", ""))
            items.append(item("disk", pct < 90, f"{pct} % belegt"))
        except Exception:
            items.append(item("disk", False, out or "n/a"))

        out = mem_available_text()
        try:
            avail_mb = int(out) // 1024
            items.append(item("ram", avail_mb >= 100, f"{avail_mb} MB frei"))
        except Exception:
            items.append(item("ram", False, "n/a"))

        out = temp_text()
        try:
            temp = float(out)
            items.append(item("temp", temp < 80, f"{temp:.1f} °C"))
        except Exception:
            items.append(item("temp", True, "n/a"))

        rc, out, _ = run(["vcgencmd", "get_throttled"])
        th_ok = "0x0" in out.replace(" ", "")
        items.append(item("throttle", th_ok or rc != 0, out or "n/a"))

        out = chrony_text()
        items.append(item("chrony", bool(out), "tracking OK" if out else "fail"))

        out = apt_upgradable_text()
        try:
            n = int(out.strip().splitlines()[-1])
        except Exception:
            n = -1
        items.append(item("apt", n == 0, f"{n} Updates" if n >= 0 else "n/a"))

    except Exception as e:
        log(f"ERROR {e}")
        items.append(item("internal", False, str(e)[:80]))

    critical = [i for i in items if i["id"] != "apt"]
    ok = all(i["ok"] for i in critical)
    data = {
        "ok": ok,
        "score": sum(1 for i in items if i["ok"]),
        "max": len(items),
        "at": now_str(),
        "items": items,
    }
    try:
        tmp = OUT.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        tmp.replace(OUT)
    except Exception as e:
        log(f"write JSON fail: {e}")
    log(f"done ok={ok} score={data['score']}/{data['max']}")
    return 0

def selftest_fake():
    """Warte-Logik mit Fakes (nichts wird geprueft). # sysBoot"""
    assert wait_plan(None, 900) == (0.0, True)
    assert wait_plan(700, 900) == (0.0, True)
    w, go = wait_plan(30, 900)
    assert go and 570 <= w <= 580
    assert wait_plan(30, 90) == (0.0, False)
    assert wait_plan(550, 160) == (55, True)
    print("health_check sysBoot selftest ok (wartet bis Dashboard 10 min alt, sonst letzter Bericht bleibt)")
    return 0


def selftest_sechard():
    """secHard: Ersatz der Shell-Aufrufe und von exec(config.py) mit Fakes (nichts Echtes geprueft). # secHard"""
    import tempfile
    global log
    log_orig = log
    log = lambda msg: None                                                    # der Selbsttest schreibt nichts ins echte health_check.log
    assert run("echo hallo") == (1, "", "run: Argumentliste erwartet")        # Text statt Liste wird abgelehnt
    assert run([]) == (1, "", "run: Argumentliste erwartet")
    rc, out, _ = run(["echo", "a b; echo c"])
    assert rc == 0 and out == "a b; echo c"                                   # keine Shell: ; wird nicht ausgefuehrt
    rc, out, err = run(["sh", "-c", "exit 3"])
    assert rc == 3 and out == ""
    assert run(["/nicht/vorhanden/xyz"])[0] == 1
    assert run(["sleep", "5"], timeout=0.2)[0] == 1
    assert run(["pwd"], cwd="/tmp")[1] in ("/tmp", os.path.realpath("/tmp"))
    d = pathlib.Path(tempfile.mkdtemp(prefix="hcst-"))
    try:
        def cfg(text):
            (d / "config.py").write_text(text, encoding="utf-8")
            return mesh_host(d / "config.py")
        assert cfg('MESHTASTIC_HOST = "10.1.2.3"\n') == "10.1.2.3"
        assert cfg('X = 1\nMESHTASTIC_HOST = "a"\nMESHTASTIC_HOST = "meshbox.local"\n') == "meshbox.local"   # letzte Zuweisung gilt
        assert cfg('MESHTASTIC_HOST: str = "10.9.9.9"\n') == "10.9.9.9"
        assert cfg('# nichts\nPORT = 5000\n') == DEFAULT_MESH_HOST
        assert cfg('MESHTASTIC_HOST = 5\n') == DEFAULT_MESH_HOST
        marker = d / "ausgefuehrt"
        assert cfg('open(%r, "w").write("x")\nMESHTASTIC_HOST = "10.7.7.7"\n' % str(marker)) == "10.7.7.7"
        assert not marker.exists()                                             # config.py wird NICHT ausgefuehrt
        assert cfg('import os\nMESHTASTIC_HOST = os.environ.get("X", "1.1.1.1")\n') == DEFAULT_MESH_HOST   # kein einfacher Text -> Standardwert
        assert cfg('MESHTASTIC_HOST = "1.2.3.4; reboot"\n') == DEFAULT_MESH_HOST
        assert cfg('MESHTASTIC_HOST = "-oProxyCommand=x"\n') == DEFAULT_MESH_HOST
        assert cfg('MESHTASTIC_HOST = "fe80::1"\n') == "fe80::1"
        assert cfg('def kaputt(:\n') == DEFAULT_MESH_HOST                     # Syntaxfehler -> Standardwert
        assert mesh_host(d / "gibt-es-nicht.py") == DEFAULT_MESH_HOST
        mp = d / "meminfo"
        mp.write_text("MemTotal:  3999 kB\nMemAvailable:    123456 kB\nSwapTotal: 0 kB\n")
        assert mem_available_text(mp) == "123456"
        assert mem_available_text(d / "fehlt") == ""
    finally:
        log = log_orig
        for p in d.iterdir():
            p.unlink()
        d.rmdir()
    assert all(host_ok(x) for x in ("192.168.178.141", "mesh-1.local", "fe80::1", "a"))
    assert not any(host_ok(x) for x in ("", "-x", "a b", "a;b", "a$(x)", "a`x`", "a|b", 5, None, "x" * 300))
    print("health_check secHard selftest ok (keine Shell, config.py wird nicht ausgefuehrt, Hostpruefung, Fakes)")
    return 0

if __name__ == "__main__":
    if "--selftest-fake" in sys.argv[1:]:
        rc1 = selftest_fake()
        raise SystemExit(rc1 or selftest_sechard())
    raise SystemExit(main())
SEC_HC_EOF
EXPECT_XML="c4db8c5c070afc3f0bb9504b315c8c7cc5f53fac879de42f217cdaba7dd2456b"
cat > "$W/lage_xml.py" << 'SEC_XML_EOF'
#!/usr/bin/env python3
"""lage_xml.py (secHard, SEC-11): gehaertetes Parsen externer XML-Feeds (Notdienst, Nachrichten-RSS).

Nicht von selbst aktiv: dashboard.py muss es aufrufen (Einbindungstext in INTEGRATION.md). Bis dahin aendert diese Datei nichts.

  safe_fromstring(daten, max_bytes=None)  Ersatz fuer xml.etree.ElementTree.fromstring (gleiches Ergebnis, ein Element)
  limited_content(antwort, max_bytes)     liest eine requests-Antwort (stream=True) mit Obergrenze statt r.content
  status()                                ehrliche Statusmeldung: welcher Parser, welche Grenze

Mit defusedxml (falls im venv vorhanden): Entity-Deklarationen und externe Verweise werden abgelehnt (DTD bleibt erlaubt, RSS
hat oft eine). Ohne defusedxml: Rueckfall auf den bisherigen Parser xml.etree MIT Groessenlimit, und das wird einmal im Journal
gemeldet und in status() ausgewiesen (kein stilles Weitermachen). Es wird nichts installiert.
Fehler: XmlRejected (Unterklasse von xml.etree.ElementTree.ParseError, also von SyntaxError) bei abgelehntem oder zu grossem XML.
"""
import sys
import xml.etree.ElementTree as ET

try:
    from defusedxml import ElementTree as _DET
    from defusedxml import DefusedXmlException as _DXE
    HARD = True
except Exception:   # nicht installiert oder unbrauchbar -> Rueckfall (ehrlich gemeldet)
    _DET = None
    _DXE = None
    HARD = False

MAX_BYTES_DEFAULT = 4 * 1024 * 1024   # 4 MiB; Aufrufer duerfen eine kleinere/groessere Grenze nach den beobachteten Feedgroessen waehlen
_noted = False


class XmlRejected(ET.ParseError):
    """XML abgelehnt (zu gross oder gefaehrliche Konstrukte)."""


def status():
    return {
        "hard": HARD,
        "backend": "defusedxml" if HARD else "xml.etree (Rueckfall: defusedxml fehlt, nur Groessenlimit)",
        "max_bytes": MAX_BYTES_DEFAULT,
        "msg": ("defusedxml aktiv: Entity-Deklarationen und externe Verweise werden abgelehnt" if HARD else
                "defusedxml ist nicht im venv: es gilt der bisherige Parser xml.etree mit Groessenlimit (kein zusaetzlicher Entity-Schutz ueber expat hinaus)"),
    }


def _note_once():
    global _noted
    if not _noted:
        _noted = True
        print("lage_xml: " + status()["msg"], file=sys.stderr, flush=True)


def _size(daten):
    return len(daten.encode("utf-8")) if isinstance(daten, str) else len(daten)


def safe_fromstring(daten, max_bytes=None):
    lim = MAX_BYTES_DEFAULT if max_bytes is None else int(max_bytes)
    n = _size(daten)
    if n > lim:
        raise XmlRejected("XML zu gross: %d Bytes (Grenze %d)" % (n, lim))
    if HARD:
        try:
            return _DET.fromstring(daten, forbid_dtd=False, forbid_entities=True, forbid_external=True)
        except _DXE as e:
            raise XmlRejected("XML abgelehnt (%s)" % type(e).__name__) from None
    _note_once()
    return ET.fromstring(daten)


def limited_content(antwort, max_bytes=None, chunk=65536):
    """Bytes einer requests-Antwort (mit stream=True geholt) lesen; bricht bei Ueberschreitung ab und schliesst die Antwort."""
    lim = MAX_BYTES_DEFAULT if max_bytes is None else int(max_bytes)
    try:
        cl = int(antwort.headers.get("Content-Length") or 0)
    except Exception:
        cl = 0
    if cl > lim:
        antwort.close()
        raise XmlRejected("Antwort zu gross: Content-Length %d (Grenze %d)" % (cl, lim))
    buf = bytearray()
    for part in antwort.iter_content(chunk_size=chunk):
        buf += part
        if len(buf) > lim:
            antwort.close()
            raise XmlRejected("Antwort zu gross: mehr als %d Bytes" % lim)
    return bytes(buf)


def selftest():
    global HARD, _noted
    ok_xml = b'<?xml version="1.0"?><rss><channel><item><title>T\xc3\xa4st</title></item></channel></rss>'
    laughs = (b'<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">'
              b'<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><l>&c;</l>')
    doctype_only = b'<?xml version="1.0"?><!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd"><rss version="0.91"><channel><title>x</title></channel></rss>'
    saved = HARD
    try:
        for mode in ([True, False] if saved else [False]):
            HARD = mode
            _noted = False
            r = safe_fromstring(ok_xml)
            assert r.tag == "rss" and r.find("channel/item/title").text == "T\u00e4st"
            assert safe_fromstring(ok_xml.decode("utf-8")).tag == "rss"    # Text statt Bytes geht (ohne encoding-Angabe im Kopf)
            try:
                safe_fromstring(b"x" * 1000, max_bytes=999)
                raise AssertionError("zu grosses XML nicht abgelehnt")
            except XmlRejected:
                pass
            assert safe_fromstring(b"<a/>" + b" " * 10, max_bytes=14).tag == "a"      # genau an der Grenze ok
            if mode:
                for bad in (laughs,):
                    try:
                        safe_fromstring(bad)
                        raise AssertionError("Entity-Bombe nicht abgelehnt")
                    except XmlRejected:
                        pass
                assert safe_fromstring(doctype_only).tag == "rss"                       # DTD ohne Entities bleibt erlaubt
                assert status()["hard"] is True
            else:
                assert status()["hard"] is False and "Rueckfall" in status()["backend"]
                assert _noted is True
    finally:
        HARD = saved

    class FakeResp:
        def __init__(self, parts, cl=None):
            self._p = parts
            self.headers = {"Content-Length": str(cl)} if cl is not None else {}
            self.closed = False

        def iter_content(self, chunk_size=0):
            for p in self._p:
                yield p

        def close(self):
            self.closed = True

    assert limited_content(FakeResp([b"ab", b"cd"]), 4) == b"abcd"
    r = FakeResp([b"abc", b"def"])
    try:
        limited_content(r, 5)
        raise AssertionError("Grenze nicht erkannt")
    except XmlRejected:
        assert r.closed
    r = FakeResp([b"a"], cl=10 ** 9)
    try:
        limited_content(r, 100)
        raise AssertionError("Content-Length nicht erkannt")
    except XmlRejected:
        assert r.closed
    return "lage_xml selftest ok (Parser: %s)" % ("defusedxml und Rueckfall" if saved else "nur Rueckfall, defusedxml nicht vorhanden")


if __name__ == "__main__":
    if "--status" in sys.argv[1:]:
        print(status())
    else:
        print(selftest())
SEC_XML_EOF
EXPECT_REQS="a6bf962c0a3abdd8df7eeaf76fbf2f1cc822bfd4d863df2e5ac8353f330e14f1"
cat > "$W/lage_reqs.py" << 'SEC_REQS_EOF'
#!/usr/bin/env python3
"""lage_reqs.py (secHard, SEC-10): Abhaengigkeiten des Dashboards pruefen und requirements-Vorlage erzeugen. NUR LESEND - installiert nichts.

  python3 tools/lage_reqs.py check               Fremd-Importe der Projektdateien gegen das venv: installiert (Version) oder FEHLT
  python3 tools/lage_reqs.py vorlage             requirements-Text aus dem venv (Versionen), Hashes als gekennzeichnete Platzhalter
  python3 tools/lage_reqs.py hashes --netz       wie vorlage, Hashes aus PyPI (nur lesender Abruf von pypi.org; Paketname+Version werden uebertragen)
Optionen: --projekt ORDNER (Standard: Ordner ueber tools/), --venv ORDNER (Standard: PROJEKT/venv), --out DATEI (statt Bildschirm; ueberschreibt nie)
Ohne --out wird nur ausgegeben, nichts geschrieben. Die Datei requirements.txt wird nie von selbst angelegt oder ersetzt.
"""
import ast
import json
import os
import subprocess
import sys

SKIP_DIRS = {"venv", "__pycache__", "backups", ".git", "node_modules"}
VENV_SCRIPT = r'''
import importlib.metadata as md, importlib.util, json, sys
mods = json.loads(sys.argv[1])
dists = []
for d in md.distributions():
    n = d.metadata["Name"] or ""
    if not n:
        continue
    direct = d.read_text("direct_url.json")
    dists.append({"name": n, "version": d.version, "direct": bool(direct)})
pd = md.packages_distributions()
res = {}
for m in mods:
    try:
        found = importlib.util.find_spec(m) is not None
    except Exception:
        found = False
    res[m] = {"found": found, "dists": sorted(set(pd.get(m, [])))}
print(json.dumps({"python": sys.version.split()[0], "dists": dists, "mods": res}))
'''


def py_files(root):
    out = []
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.startswith(".")]
        for f in fn:
            if f.endswith(".py"):
                out.append(os.path.join(dp, f))
    return sorted(out)


def local_names(root):
    names = set()
    for e in os.listdir(root):
        p = os.path.join(root, e)
        if e.endswith(".py"):
            names.add(e[:-3])
        elif os.path.isdir(p) and e not in SKIP_DIRS:
            names.add(e)
    return names


def scan_imports(root):
    """-> {top_level_name: {"optional": bool, "files": set}}; optional = nur innerhalb try/except ImportError bzw. in Funktionen mit try."""
    std = set(sys.stdlib_module_names) | {"__future__"}
    loc = local_names(root)
    found = {}
    for f in py_files(root):
        try:
            tree = ast.parse(open(f, encoding="utf-8", errors="replace").read())
        except SyntaxError:
            continue
        guarded = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Try) and any(
                    (h.type is None) or any(isinstance(x, ast.Name) and x.id in ("ImportError", "ModuleNotFoundError", "Exception") for x in ast.walk(h.type))
                    for h in n.handlers):
                for b in n.body:
                    for x in ast.walk(b):
                        guarded.add(id(x))
        for n in ast.walk(tree):
            names = []
            if isinstance(n, ast.Import):
                names = [a.name.split(".")[0] for a in n.names]
            elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                names = [n.module.split(".")[0]]
            for m in names:
                if m in std or m in loc:
                    continue
                e = found.setdefault(m, {"optional": True, "files": set()})
                if id(n) not in guarded:
                    e["optional"] = False
                e["files"].add(os.path.relpath(f, root))
    return found


def venv_info(venv, mods):
    py = os.path.join(venv, "bin", "python")
    if not os.access(py, os.X_OK):
        raise SystemExit("venv-Python nicht gefunden: %s (Option --venv ORDNER)" % py)
    p = subprocess.run([py, "-c", VENV_SCRIPT, json.dumps(sorted(mods))], capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise SystemExit("venv-Abfrage fehlgeschlagen: %s" % (p.stderr or p.stdout)[-300:])
    return json.loads(p.stdout)


def norm(n):
    return n.lower().replace("_", "-").replace(".", "-")


def pins(info):
    skip = {"pip", "setuptools", "wheel"}
    out, manual, seen = [], [], set()
    for d in sorted(info["dists"], key=lambda x: norm(x["name"])):
        if norm(d["name"]) in skip or norm(d["name"]) in seen:
            continue
        seen.add(norm(d["name"]))
        (manual if d["direct"] else out).append((d["name"], d["version"]))
    return out, manual


def cmd_check(root, venv):
    imp = scan_imports(root)
    info = venv_info(venv, imp.keys())
    print("Projekt: %s | venv: %s | venv-Python %s" % (root, venv, info["python"]))
    miss = 0
    for m in sorted(imp):
        r = info["mods"][m]
        ds = r["dists"]
        ver = ""
        if ds:
            vs = {norm(d["name"]): d["version"] for d in info["dists"]}
            ver = ", ".join("%s %s" % (d, vs.get(norm(d), "?")) for d in ds)
        art = "optional (try/except ImportError)" if imp[m]["optional"] else "direkt"
        if r["found"]:
            print("  OK     %-14s im venv (%s) | %s | %d Datei(en)" % (m, ver or "Paket unbekannt", art, len(imp[m]["files"])))
        else:
            miss += 1
            print("  FEHLT  %-14s NICHT im venv | %s | %s" % (m, art, ", ".join(sorted(imp[m]["files"]))[:120]))
    print("Ergebnis: %d Fremdpakete im Quelltext, %d fehlen im venv. Es wurde nichts installiert." % (len(imp), miss))
    return 1 if miss else 0


def render(root, venv, hashes=None):
    imp = scan_imports(root)
    info = venv_info(venv, imp.keys())
    out, manual = pins(info)
    lines = ["# requirements aus dem venv %s (Python %s) - erzeugt mit tools/lage_reqs.py" % (venv, info["python"])]
    if hashes is None:
        lines.append("# ACHTUNG VORLAGE: Zeilen mit HIER-HASH-EINTRAGEN sind Platzhalter. So NICHT mit pip install --require-hashes benutzen.")
        lines.append("# Echte Hashes: python3 tools/lage_reqs.py hashes --netz --out requirements.neu")
    else:
        lines.append("# Installation (nur wenn noetig, als Benutzer fmg, nie als root): venv/bin/pip install --require-hashes -r requirements.txt")
    direct = {norm(d) for m in imp for d in info["mods"][m]["dists"]}
    for name, ver in out:
        tag = "  # direkt importiert" if norm(name) in direct else ""
        if hashes is None:
            lines.append("%s==%s \\\n    --hash=sha256:HIER-HASH-EINTRAGEN%s" % (name, ver, tag))
        else:
            hs = hashes.get((norm(name), ver))
            if hs:
                lines.append("%s==%s \\\n%s%s" % (name, ver, " \\\n".join("    --hash=sha256:%s" % h for h in hs), tag))
            else:
                lines.append("# KEIN HASH GEFUNDEN: %s==%s (nicht auf PyPI?) - manuell pruefen" % (name, ver))
    for name, ver in manual:
        lines.append("# manuell pruefen (lokal/URL installiert, nicht aus PyPI): %s==%s" % (name, ver))
    for m in sorted(imp):
        if not info["mods"][m]["found"]:
            lines.append("# FEHLT im venv: %s (importiert in %s)" % (m, ", ".join(sorted(imp[m]["files"]))[:100]))
    return "\n".join(lines) + "\n", out


def pypi_hashes(out, fetch=None):
    import urllib.request
    fetch = fetch or (lambda u: json.load(urllib.request.urlopen(u, timeout=20)))
    res = {}
    for name, ver in out:
        try:
            d = fetch("https://pypi.org/pypi/%s/%s/json" % (name, ver))
            hs = sorted({f["digests"]["sha256"] for f in d.get("urls", []) if f.get("digests", {}).get("sha256")})
            if hs:
                res[(norm(name), ver)] = hs
        except Exception:
            pass
    return res


def main(argv):
    a = list(argv)
    opts = {"--projekt": None, "--venv": None, "--out": None}
    netz = "--netz" in a
    if netz:
        a.remove("--netz")
    for k in list(opts):
        if k in a:
            i = a.index(k)
            opts[k] = a[i + 1] if i + 1 < len(a) else None
            del a[i:i + 2]
    cmd = a[0] if a else ""
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(opts["--projekt"] or os.path.dirname(here))
    venv = os.path.abspath(opts["--venv"] or os.path.join(root, "venv"))
    if cmd == "check":
        return cmd_check(root, venv)
    if cmd in ("vorlage", "hashes"):
        if cmd == "hashes" and not netz:
            print("hashes braucht --netz (ruft pypi.org lesend ab). Ohne Netz: vorlage.")
            return 2
        if cmd == "hashes":
            _, out = render(root, venv)
            text, _ = render(root, venv, pypi_hashes(out))
        else:
            text, _ = render(root, venv)
        if opts["--out"]:
            if os.path.exists(opts["--out"]):
                print("STOP: %s gibt es schon - es wird nie ueberschrieben." % opts["--out"])
                return 2
            with open(opts["--out"], "x", encoding="utf-8") as f:
                f.write(text)
            print("geschrieben: %s (%d Zeilen)" % (opts["--out"], text.count("\n")))
        else:
            sys.stdout.write(text)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
SEC_REQS_EOF
EXPECT_VORL="e6bb839311fc250252dc3aff87a718bb11aaecb1e7794e360b5a931e501a3f4c"
cat > "$W/requirements.txt.vorlage" << 'SEC_VORL_EOF'
# requirements.txt.VORLAGE (secHard, SEC-10) - KEINE benutzbare requirements.txt, nichts davon wird automatisch angewendet.
# Stand: Fremd-Importe aus dem Quelltext (Branch kaeswasser-lage-monitor); Versionen und Hashes gibt es nur im venv auf dem Pi.
# So wird daraus die echte Datei (alles nur lesend, nichts wird installiert):
#   1. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py check                     zeigt, was im venv fehlt (z. B. psutil, defusedxml)
#   2. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py vorlage                   Versionen aus dem venv, Hashes als Platzhalter
#   3. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py hashes --netz --out /home/fmg/requirements.neu     echte Hashes von PyPI (lesender Abruf)
#   4. Ergebnis pruefen und erst dann als requirements.txt einchecken. Pruefung ohne Installation: venv/bin/pip install --dry-run --require-hashes -r DATEI
# Zeilen mit HIER-... sind Platzhalter und duerfen NICHT mit pip install benutzt werden.
#
# Direkte Importe (nach Haeufigkeit/Wichtigkeit):
Flask==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
requests==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
ntplib==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
psutil==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
numpy==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
meshtastic==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
PyPubSub==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
# Optional (nur wenn im venv vorhanden; Importe sind mit try/except abgesichert):
#   Pillow (PIL), gpiozero, sgp4 (liegt auch als Quelltext in sdr_lib/)
#   defusedxml  - fuer lage_xml.py (SEC-11); fehlt es, gilt der Rueckfall mit Groessenlimit
# Dazu kommen die abhaengigen Pakete (Werkzeug, Jinja2, urllib3, certifi, protobuf, ...): lage_reqs.py vorlage nimmt ALLE Pakete des venv auf.
# Hinweis: Die Bridges (mesh_bridge*.py) koennen eine andere Python-Umgebung nutzen als das Dashboard-venv - dann dafuer eine eigene Liste fuehren.
SEC_VORL_EOF
EXPECT_GUARD="dc710b486ee4bed013fca9bddd05b618373f3b87c7469577ac07556cf48b021f"
cat > "$W/guard_sechard.py" << 'SEC_GUARD_EOF'
#!/usr/bin/env python3
"""guard_sechard.py - AST-Pruefung fuer secHard (health_check.py, lage_xml.py, tools/lage_reqs.py) samt Mutationstest.
  check HEALTH_PY XML_PY REQS_PY BASE_HEALTH_PY   -> Exit 0 = alle Pruefungen ok
  mutate BASE_HEALTH_PY EDITS_PY XML_PY REQS_PY   -> jede Mutation einzeln anwenden, jede muss von check erkannt werden
"""
import ast
import importlib.util
import pathlib
import sys

KEEP_FUNCS = ["dash_age_s", "own_budget_s", "wait_plan", "fetch_page", "now_str", "log", "item", "selftest_fake"]
KEEP_ASSIGN = ["BASE", "OUT", "LOG", "PAGES", "DASH_MIN_AGE_S", "PAGE_TIMEOUT_S", "RETRY_PAUSE_S"]
BAD_CALLS = {"exec", "eval", "compile", "__import__"}
BAD_ATTR = {("os", "system"), ("os", "popen"), ("os", "execv"), ("os", "execvp"), ("os", "spawnl"), ("subprocess", "getoutput"),
            ("subprocess", "getstatusoutput"), ("subprocess", "call"), ("subprocess", "check_output"), ("subprocess", "check_call")}


def dump(n):
    return ast.dump(n, include_attributes=False)


def top_assign(tree, name):
    for n in tree.body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in n.targets):
            return n
    return None


def fdef(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    return None


def imports(tree):
    s = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            s |= {a.name for a in n.names}
        elif isinstance(n, ast.ImportFrom):
            s.add(n.module or "")
    return s


def call_name(c):
    f = c.func
    if isinstance(f, ast.Name):
        return f.id, None
    if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name):
        return f.value.id, f.attr
    return None, None


def common_bad(tree, errs, allowed_sub_funcs=()):
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            a, b = call_name(n)
            if b is None and a in BAD_CALLS:
                errs.append("verbotener Aufruf %s() in Zeile %d" % (a, n.lineno))
            if (a, b) in BAD_ATTR:
                errs.append("verbotener Aufruf %s.%s() in Zeile %d" % (a, b, n.lineno))
            for kw in n.keywords:
                if kw.arg == "shell" and not (isinstance(kw.value, ast.Constant) and kw.value.value is False):
                    errs.append("shell= in Zeile %d" % n.lineno)
            if (a, b) in (("subprocess", "run"), ("subprocess", "Popen")):
                owner = None
                for f in ast.walk(tree):
                    if isinstance(f, ast.FunctionDef) and any(x is n for x in ast.walk(f)):
                        owner = f.name
                if owner not in allowed_sub_funcs:
                    errs.append("subprocess.%s ausserhalb der erlaubten Funktionen (%s) in Zeile %d" % (b, owner, n.lineno))
                first = n.args[0] if n.args else None
                ok = isinstance(first, ast.List) or (isinstance(first, ast.Call) and call_name(first) == ("list", None))
                if not ok:
                    errs.append("subprocess.%s ohne Argumentliste in Zeile %d" % (b, n.lineno))


def check_hc(src, base_src):
    errs = []
    try:
        t = ast.parse(src)
        b = ast.parse(base_src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    common_bad(t, errs, allowed_sub_funcs=("run", "apt_upgradable_text", "dash_age_s", "own_budget_s"))
    # alle run(...)-Aufrufe: erstes Argument eine Liste ohne f-Strings/Verkettung
    nrun = 0
    selft = fdef(t, "selftest_sechard")
    selfids = {id(x) for x in ast.walk(selft)} if selft else set()
    for n in ast.walk(t):
        if isinstance(n, ast.Call) and call_name(n) == ("run", None):
            if id(n) in selfids:
                continue                       # der Selbsttest ruft run() absichtlich mit Text/leer auf (muss abgelehnt werden)
            nrun += 1
            f = n.args[0] if n.args else None
            if not isinstance(f, ast.List):
                errs.append("run() ohne Listenliteral in Zeile %d" % n.lineno)
                continue
            for e in f.elts:
                if isinstance(e, (ast.JoinedStr, ast.BinOp)) or not isinstance(e, (ast.Constant, ast.Name, ast.Call)):
                    errs.append("run()-Argument mit Verkettung/f-String in Zeile %d" % n.lineno)
                if isinstance(e, ast.Constant) and not isinstance(e.value, str):
                    errs.append("run()-Argument kein Text in Zeile %d" % n.lineno)
    if nrun < 6:
        errs.append("zu wenige run()-Aufrufe (%d)" % nrun)
    imp = imports(t)
    plain = {a.name for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names}
    if not {"ast", "os", "pathlib"} <= plain:
        errs.append("Importe ast/os/pathlib fehlen")
    extra = imp - imports(b) - {"ast", "os", "pathlib", "tempfile"}
    if extra:
        errs.append("zusaetzliche Importe: %s" % sorted(extra))
    # run(): Liste verlangt, kein shell
    rf = fdef(t, "run")
    if rf is None or "isinstance(cmd, (list, tuple))" not in (ast.get_source_segment(src, rf) or ""):
        errs.append("run() prueft nicht auf Argumentliste")
    # Konfiguration ohne exec
    cf = fdef(t, "config_text_value")
    cs = ast.get_source_segment(src, cf) if cf else ""
    if not cf or "ast.parse" not in cs or "ast.literal_eval" not in cs:
        errs.append("config_text_value ohne ast.parse/literal_eval")
    mh = fdef(t, "mesh_host")
    ms = ast.get_source_segment(src, mh) if mh else ""
    if not mh or "config_text_value" not in ms or "host_ok" not in ms:
        errs.append("mesh_host nutzt config_text_value/host_ok nicht")
    if "exec" in ms or "open(" in ms:
        errs.append("mesh_host: exec/open")
    hf = fdef(t, "host_ok")
    hs = ast.get_source_segment(src, hf) if hf else ""
    if not hf or "_HOST_RE.match" not in hs or 'startswith("-")' not in hs or "isinstance(h, str)" not in hs:
        errs.append("host_ok unvollstaendig")
    # Hostpruefung vor nc: der nc-Aufruf nutzt host aus mesh_host() (kein anderer Ursprung)
    mn = fdef(t, "main")
    mnsrc = ast.get_source_segment(src, mn) if mn else ""
    if "host = mesh_host()" not in mnsrc or '"nc", "-z", "-w2", host, "4403"' not in mnsrc:
        errs.append("nc-Aufruf nicht wie erwartet (host = mesh_host())")
    # unveraenderte Teile
    for name in KEEP_FUNCS:
        a, c = fdef(t, name), fdef(b, name)
        if a is None or c is None or dump(a) != dump(c):
            errs.append("Funktion %s fehlt oder wurde veraendert" % name)
    for name in KEEP_ASSIGN:
        a, c = top_assign(t, name), top_assign(b, name)
        if a is None or c is None or dump(a) != dump(c):
            errs.append("Konstante %s fehlt oder wurde veraendert" % name)
    for n in b.body:
        if isinstance(n, ast.FunctionDef) and fdef(t, n.name) is None:
            errs.append("Basisfunktion entfernt: %s" % n.name)
    # Pruefpunkte, Schwellen, Texte der Ausgabe wie in der Basis
    def item_ids(tree):
        out = []
        for n in ast.walk(tree):
            if isinstance(n, ast.Call) and call_name(n) == ("item", None) and n.args:
                out.append(ast.unparse(n.args[0]))
        return sorted(out)
    if item_ids(t) != item_ids(b):
        errs.append("Pruefpunkte (item-ids) weichen von der Basis ab: %s vs %s" % (item_ids(t), item_ids(b)))
    def cmps(tree):
        out = []
        fn = fdef(tree, "main")
        for n in ast.walk(fn):
            if isinstance(n, ast.Compare) and not ast.unparse(n.left).startswith("rc"):   # rc-Vergleiche: chrony bewusst nur noch auf Text (wie bisher durch head)
                for c in n.comparators:
                    if isinstance(c, ast.Constant) and isinstance(c.value, (int, float)) and not isinstance(c.value, bool):
                        out.append((ast.unparse(n.left)[:20], type(n.ops[0]).__name__, c.value))
        return sorted(out, key=str)
    if cmps(t) != cmps(b):
        errs.append("Schwellen in main() weichen ab: %s vs %s" % (cmps(t), cmps(b)))
    def msgs(tree):
        fn = fdef(tree, "main")
        return sorted(ast.unparse(n) for n in ast.walk(fn) if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value not in ())
    bm, tm = msgs(b), msgs(t)
    lost = [x for x in bm if x not in tm and "'" not in x or False]
    # Texte der Basis, die als Anzeigetexte dienen, muessen erhalten bleiben
    for must in ("Syntax OK", "FAIL", "inactive", "active", "n/a", "tracking OK", "fail", "kiwix", "mesh", "disk", "ram", "temp", "throttle", "chrony", "apt", "compile", "internal"):
        if repr(must) not in tm:
            errs.append("Text/Id %r fehlt in main()" % must)
    # Selbsttest eingebunden
    if fdef(t, "selftest_sechard") is None or "selftest_sechard()" not in src.split('if __name__ == "__main__":')[-1]:
        errs.append("selftest_sechard nicht eingebunden")
    if "secHard" not in (ast.get_docstring(t) or ""):
        errs.append("Modul-Docstring ohne secHard")
    return errs


def check_xml(src):
    errs = []
    try:
        t = ast.parse(src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    common_bad(t, errs)
    imp = imports(t)
    if imp - {"sys", "xml.etree.ElementTree", "defusedxml"}:
        errs.append("unerwartete Importe: %s" % sorted(imp - {"sys", "xml.etree.ElementTree", "defusedxml"}))
    f = fdef(t, "safe_fromstring")
    fs = ast.get_source_segment(src, f) if f else ""
    if not f:
        return errs + ["safe_fromstring fehlt"]
    if "n > lim" not in fs or "raise XmlRejected" not in fs:
        errs.append("safe_fromstring ohne Groessenpruefung")
    i_size, i_parse = fs.find("n > lim"), fs.find("_DET.fromstring(")
    if not (0 <= i_size < i_parse):
        errs.append("Groessenpruefung nicht VOR dem Parsen")
    if "forbid_entities=True" not in fs or "forbid_external=True" not in fs or "forbid_dtd=False" not in fs:
        errs.append("defusedxml-Parameter nicht wie vorgesehen")
    if "_note_once()" not in fs:
        errs.append("Rueckfall ohne ehrliche Meldung (_note_once)")
    import re as _re
    mm = [m.start() for m in _re.finditer(r"(?<!_D)ET\.fromstring\(", fs)]
    if len(mm) != 1 or fs.find("_note_once()") > mm[0]:
        errs.append("Rueckfallparser nicht genau einmal und nicht nach der Meldung")
    if "XMLParser" in src or "XMLPullParser" in src or "ET.parse(" in src:
        errs.append("anderer Parser")
    lc = fdef(t, "limited_content")
    ls = ast.get_source_segment(src, lc) if lc else ""
    if not lc or "iter_content" not in ls or "len(buf) > lim" not in ls or "Content-Length" not in ls:
        errs.append("limited_content unvollstaendig")
    if "class XmlRejected(ET.ParseError)" not in src:
        errs.append("XmlRejected nicht von ParseError abgeleitet")
    if "MAX_BYTES_DEFAULT = 4 * 1024 * 1024" not in src:
        errs.append("Standardgrenze geaendert")
    return errs


def check_reqs(src):
    errs = []
    try:
        t = ast.parse(src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    common_bad(t, errs, allowed_sub_funcs=("venv_info",))
    for n in ast.walk(t):
        if isinstance(n, ast.Call):
            a, b = call_name(n)
            if (a, b) == ("subprocess", "run"):
                strs = [x.value for x in ast.walk(n) if isinstance(x, ast.Constant) and isinstance(x.value, str)]
                if any("install" in s or "pip" == s for s in strs):
                    errs.append("subprocess-Aufruf mit install/pip in Zeile %d" % n.lineno)
            if a is None and b is None and isinstance(n.func, ast.Name) and n.func.id == "open":
                pass
            if isinstance(n.func, ast.Name) and n.func.id == "open":
                mode = None
                if len(n.args) > 1 and isinstance(n.args[1], ast.Constant):
                    mode = n.args[1].value
                for kw in n.keywords:
                    if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
                        mode = kw.value.value
                if mode is not None and any(c in str(mode) for c in "wa+") :
                    errs.append("open() mit Schreibmodus %r in Zeile %d" % (mode, n.lineno))
    if '"x"' not in src or 'os.path.exists(opts["--out"])' not in src:
        errs.append("--out ueberschreibt nicht sicher (x-Modus/Existenzpruefung)")
    if "ru" "n_pip" in src:
        errs.append("pip-Ausfuehrung")
    if "--netz" not in src or 'cmd == "hashes" and not netz' not in src:
        errs.append("hashes ohne --netz-Schutz")
    return errs


def check(hc, xml, reqs, base):
    e = ["health_check: " + x for x in check_hc(hc, base)]
    e += ["lage_xml: " + x for x in check_xml(xml)]
    e += ["lage_reqs: " + x for x in check_reqs(reqs)]
    return e


def mutants(hc, xml, reqs, edits_mod, base):
    M = []
    def sub(name, which, old, new, count=1):
        M.append((name, which, old, new))
    sub("M01 shell=True in run", "hc", "list(cmd), capture_output=True", "cmd, shell=True, capture_output=True")
    sub("M02 exec(config)", "hc", "    val = None\n    for node in ast.parse(src).body:", "    exec(src)\n    val = None\n    for node in ast.parse(src).body:")
    sub("M03 eval statt literal_eval", "hc", "val = ast.literal_eval(node.value)\n            except Exception:\n                val = None\n        elif", "val = eval(node.value)\n            except Exception:\n                val = None\n        elif")
    sub("M04 run mit Text", "hc", 'run(["systemctl", "is-active", svc])', 'run("systemctl is-active " + svc)')
    sub("M05 f-String im nc-Aufruf", "hc", '["nc", "-z", "-w2", host, "4403"]', '["nc", "-z", "-w2", f"{host}", "4403"]')
    sub("M06 host_ok nicht benutzt", "hc", "        if not host_ok(h):", "        if False:")
    sub("M07 Pruefpunkt kiwix entfernt", "hc", '        items.append(item("kiwix", k_ok, str(code)))\n', "")
    sub("M08 Schwelle disk 95", "hc", 'pct < 90', 'pct < 95')
    sub("M09 Seite aus PAGES", "hc", '    "/pegel",\n', "")
    sub("M10 os.system", "hc", "def disk_used_text(path=\"/\"):", "def disk_used_text(path=\"/\"):\n    os.system(\"true\")")
    sub("M11 dash_age_s veraendert", "hc", 'return max(0.0, float(f.read().split()[0]) - us / 1e6)', 'return float(f.read().split()[0]) - us / 1e6')
    sub("M12 host_ok ohne -", "hc", ' and not h.startswith("-")', '')
    sub("M13 Selbsttest nicht aufgerufen", "hc", "raise SystemExit(rc1 or selftest_sechard())", "raise SystemExit(rc1)")
    sub("M14 Popen shell", "hc", "def mem_available_text(path=\"/proc/meminfo\"):", "def mem_available_text(path=\"/proc/meminfo\"):\n    subprocess.Popen(\"true\", shell=True)")
    sub("M15 Anzeigetext geaendert", "hc", '"tracking OK" if out else "fail"', '"ok" if out else "fail"')
    sub("M16 subprocess.call", "hc", "def temp_text():", "def temp_text():\n    subprocess.call([\"true\"])")
    sub("M17 run erlaubt Text", "hc", "if not isinstance(cmd, (list, tuple)) or not cmd or not all(isinstance(x, str) for x in cmd):", "if False:")
    sub("X01 forbid_entities=False", "xml", "forbid_entities=True", "forbid_entities=False")
    sub("X02 Groessenpruefung entfernt", "xml", '    if n > lim:\n        raise XmlRejected("XML zu gross: %d Bytes (Grenze %d)" % (n, lim))\n', "")
    sub("X03 subprocess-Import", "xml", "import sys\n", "import sys\nimport subprocess\n")
    sub("X04 keine Meldung im Rueckfall", "xml", "    _note_once()\n    return ET.fromstring(daten)", "    return ET.fromstring(daten)")
    sub("X05 Rueckfall ohne Limit-Pruefung davor", "xml", "    return ET.fromstring(daten)\n\n\ndef limited_content", "    return ET.fromstring(daten)\n    return ET.fromstring(daten)\n\n\ndef limited_content")
    sub("X06 externe Verweise erlaubt", "xml", "forbid_external=True", "forbid_external=False")
    sub("X07 Antwortgrenze entfernt", "xml", "        if len(buf) > lim:", "        if False:")
    sub("X08 Standardgrenze", "xml", "MAX_BYTES_DEFAULT = 4 * 1024 * 1024", "MAX_BYTES_DEFAULT = 4096 * 1024 * 1024")
    sub("R01 pip install in lage_reqs", "reqs", "    p = subprocess.run([py, \"-c\", VENV_SCRIPT, json.dumps(sorted(mods))]", "    subprocess.run([py, \"-m\", \"pip\", \"install\", \"psutil\"])\n    p = subprocess.run([py, \"-c\", VENV_SCRIPT, json.dumps(sorted(mods))]")
    sub("R02 --out ueberschreibt", "reqs", 'with open(opts["--out"], "x", encoding="utf-8")', 'with open(opts["--out"], "w", encoding="utf-8")')
    sub("R03 os.system", "reqs", "def norm(n):", "def norm(n):\n    os.system(\"true\")")
    sub("R04 hashes ohne netz", "reqs", 'if cmd == "hashes" and not netz:', 'if False:')
    out = []
    for name, which, old, new in M:
        srcs = {"hc": hc, "xml": xml, "reqs": reqs}
        s = srcs[which]
        if s.count(old) != 1:
            out.append((name, None, "Muster passt %d-mal" % s.count(old)))
            continue
        srcs[which] = s.replace(old, new)
        out.append((name, check(srcs["hc"], srcs["xml"], srcs["reqs"], base), None))
    # Edit-Rueckbau
    for en, _, _ in edits_mod.EDITS:
        try:
            h2 = edits_mod.build(base, skip=(en,))
        except SystemExit as e:
            out.append(("E-revert " + en, None, str(e)))
            continue
        out.append(("E-revert " + en, check(h2, xml, reqs, base), None))
    return out


def main(argv):
    if argv[0] == "check":
        hc, xml, reqs, base = [pathlib.Path(p).read_text(encoding="utf-8") for p in argv[1:5]]
        errs = check(hc, xml, reqs, base)
        if errs:
            for e in errs:
                print("GUARD: " + e)
            return 1
        print("guard secHard ok: keine Shell, kein exec/eval, nur Argumentlisten, Hostpruefung vor nc, Pruefpunkte/Schwellen/Texte wie Basis, XML-Grenze vor Parser + ehrliche Rueckfallmeldung, lage_reqs nur lesend")
        return 0
    if argv[0] == "mutate":
        base = pathlib.Path(argv[1]).read_text(encoding="utf-8")
        spec = importlib.util.spec_from_file_location("edits", argv[2])
        em = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(em)
        hc = em.build(base)
        xml = pathlib.Path(argv[3]).read_text(encoding="utf-8")
        reqs = pathlib.Path(argv[4]).read_text(encoding="utf-8")
        assert not check(hc, xml, reqs, base), check(hc, xml, reqs, base)
        res = mutants(hc, xml, reqs, em, base)
        miss = 0
        for name, errs, bad in res:
            if bad:
                print("MUTATION %-34s FEHLER im Test: %s" % (name, bad))
                miss += 1
            elif not errs:
                print("MUTATION %-34s UEBERSEHEN" % name)
                miss += 1
        print("mutation: %d Mutationen, %d erkannt, %d uebersehen" % (len(res), len(res) - miss, miss))
        return 1 if miss else 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
SEC_GUARD_EOF
EXPECT_EDITS="928f17ce219aa4fb35aef28f72df7bff93f962935d2d2ef34246974b18135ecc"
cat > "$W/edits_sechard.py" << 'SEC_EDITS_EOF'
"""secHard: health_check.py (Basis cc3949f1896ebbf3) -> neue Fassung. Jede Ersetzung muss genau einmal passen (sonst Abbruch)."""
import pathlib
import sys

NEWRUN = '''def run(cmd, timeout=40, cwd=None):
    """secHard (SEC-09): Argumentliste statt Shell. cmd MUSS eine Liste von Texten sein (kein shell=True, keine Pipes).
    -> (returncode, stdout, stderr), jeweils gekuerzt; Fehler/Zeitlimit -> (1, "", Text) wie bisher."""
    if not isinstance(cmd, (list, tuple)) or not cmd or not all(isinstance(x, str) for x in cmd):
        return 1, "", "run: Argumentliste erwartet"
    try:
        p = subprocess.run(
            list(cmd), capture_output=True, text=True, timeout=timeout, cwd=cwd
        )
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 1, "", str(e)

def disk_used_text(path="/"):
    """Spalte 5 der zweiten Zeile von df -P (z. B. 42%). Frueher: df -P / | awk NR==2{print $5}. Fehler -> ''."""
    rc, out, _ = run(["df", "-P", path])
    lines = out.splitlines()
    if len(lines) >= 2:
        f = lines[1].split()
        if len(f) >= 5:
            return f[4]
    return ""

def mem_available_text(path="/proc/meminfo"):
    """MemAvailable in kB als Ganzzahl-Text. Frueher: awk /MemAvailable/ printf %d $2. Fehler -> ''."""
    try:
        with open(path) as f:
            for line in f:
                if "MemAvailable" in line:
                    return str(int(float(line.split()[1])))
    except Exception:
        pass
    return ""

def temp_text():
    """Ausgabe von vcgencmd measure_temp ohne die Zeichen t e m p = ' C. Frueher: ... | tr -d "temp='C". Fehler -> ''."""
    rc, out, _ = run(["vcgencmd", "measure_temp"])
    return "".join(ch for ch in out if ch not in "temp='C").strip()

def chrony_text():
    """Die ersten 6 Zeilen von chronyc tracking. Frueher: chronyc tracking | head -6 (Rueckgabewert war der von head, daher nur der Text zaehlt)."""
    rc, out, _ = run(["chronyc", "tracking"])
    return "\\n".join(out.splitlines()[:6]).strip()

def apt_upgradable_text():
    """Anzahl Zeilen von apt list --upgradable, die nicht mit Auflistung beginnen (als Text). Frueher: ... | grep -vc ^Auflistung || true.
    Zeitlimit/Fehler -> '' (Anzeige n/a), apt nicht vorhanden -> '0' wie bisher."""
    try:
        p = subprocess.run(["apt", "list", "--upgradable"], capture_output=True, text=True, errors="replace", timeout=40)
    except FileNotFoundError:
        return "0"
    except Exception:
        return ""
    return str(sum(1 for ln in (p.stdout or "").splitlines() if not ln.startswith("Auflistung")))

DEFAULT_MESH_HOST = "192.168.178.141"
_HOST_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9._-]{0,251}[A-Za-z0-9])?|[0-9A-Fa-f:]{2,45})$")

def host_ok(h):
    """Nur Hostname/IPv4/IPv6-Text, nie mit - am Anfang (keine Option fuer nc)."""
    return isinstance(h, str) and bool(_HOST_RE.match(h)) and not h.startswith("-")

def config_text_value(name, path=None):
    """secHard (SEC-09): einen einfachen Text (str) aus config.py lesen OHNE die Datei auszufuehren (ast.parse + literal_eval,
    nur oberste Ebene, die letzte Zuweisung gilt wie bei exec). Kein Text/keine Zuweisung -> None."""
    src = (path or (BASE / "config.py")).read_text(encoding="utf-8")
    val = None
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            try:
                val = ast.literal_eval(node.value)
            except Exception:
                val = None
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name and node.value is not None:
            try:
                val = ast.literal_eval(node.value)
            except Exception:
                val = None
    return val if isinstance(val, str) else None
'''

NEWMESH = '''def mesh_host(path=None):
    try:
        h = config_text_value("MESHTASTIC_HOST", path)
        if h is None:
            return DEFAULT_MESH_HOST
        if not host_ok(h):
            log("MESHTASTIC_HOST in config.py ist kein gueltiger Hostname/IP-Text - Standardwert wird geprueft")
            return DEFAULT_MESH_HOST
        return h
    except Exception:
        return DEFAULT_MESH_HOST
'''

SELFTEST = '''def selftest_sechard():
    """secHard: Ersatz der Shell-Aufrufe und von exec(config.py) mit Fakes (nichts Echtes geprueft). # secHard"""
    import tempfile
    global log
    log_orig = log
    log = lambda msg: None                                                    # der Selbsttest schreibt nichts ins echte health_check.log
    assert run("echo hallo") == (1, "", "run: Argumentliste erwartet")        # Text statt Liste wird abgelehnt
    assert run([]) == (1, "", "run: Argumentliste erwartet")
    rc, out, _ = run(["echo", "a b; echo c"])
    assert rc == 0 and out == "a b; echo c"                                   # keine Shell: ; wird nicht ausgefuehrt
    rc, out, err = run(["sh", "-c", "exit 3"])
    assert rc == 3 and out == ""
    assert run(["/nicht/vorhanden/xyz"])[0] == 1
    assert run(["sleep", "5"], timeout=0.2)[0] == 1
    assert run(["pwd"], cwd="/tmp")[1] in ("/tmp", os.path.realpath("/tmp"))
    d = pathlib.Path(tempfile.mkdtemp(prefix="hcst-"))
    try:
        def cfg(text):
            (d / "config.py").write_text(text, encoding="utf-8")
            return mesh_host(d / "config.py")
        assert cfg('MESHTASTIC_HOST = "10.1.2.3"\\n') == "10.1.2.3"
        assert cfg('X = 1\\nMESHTASTIC_HOST = "a"\\nMESHTASTIC_HOST = "meshbox.local"\\n') == "meshbox.local"   # letzte Zuweisung gilt
        assert cfg('MESHTASTIC_HOST: str = "10.9.9.9"\\n') == "10.9.9.9"
        assert cfg('# nichts\\nPORT = 5000\\n') == DEFAULT_MESH_HOST
        assert cfg('MESHTASTIC_HOST = 5\\n') == DEFAULT_MESH_HOST
        marker = d / "ausgefuehrt"
        assert cfg('open(%r, "w").write("x")\\nMESHTASTIC_HOST = "10.7.7.7"\\n' % str(marker)) == "10.7.7.7"
        assert not marker.exists()                                             # config.py wird NICHT ausgefuehrt
        assert cfg('import os\\nMESHTASTIC_HOST = os.environ.get("X", "1.1.1.1")\\n') == DEFAULT_MESH_HOST   # kein einfacher Text -> Standardwert
        assert cfg('MESHTASTIC_HOST = "1.2.3.4; reboot"\\n') == DEFAULT_MESH_HOST
        assert cfg('MESHTASTIC_HOST = "-oProxyCommand=x"\\n') == DEFAULT_MESH_HOST
        assert cfg('MESHTASTIC_HOST = "fe80::1"\\n') == "fe80::1"
        assert cfg('def kaputt(:\\n') == DEFAULT_MESH_HOST                     # Syntaxfehler -> Standardwert
        assert mesh_host(d / "gibt-es-nicht.py") == DEFAULT_MESH_HOST
        mp = d / "meminfo"
        mp.write_text("MemTotal:  3999 kB\\nMemAvailable:    123456 kB\\nSwapTotal: 0 kB\\n")
        assert mem_available_text(mp) == "123456"
        assert mem_available_text(d / "fehlt") == ""
    finally:
        log = log_orig
        for p in d.iterdir():
            p.unlink()
        d.rmdir()
    assert all(host_ok(x) for x in ("192.168.178.141", "mesh-1.local", "fe80::1", "a"))
    assert not any(host_ok(x) for x in ("", "-x", "a b", "a;b", "a$(x)", "a`x`", "a|b", 5, None, "x" * 300))
    print("health_check secHard selftest ok (keine Shell, config.py wird nicht ausgefuehrt, Hostpruefung, Fakes)")
    return 0

'''

EDITS = [
    ("E01_doc",
     'sysBoot: laeuft der Dienst prepper-dashboard',
     'secHard (SEC-09): keine Shell mehr (Argumentlisten, Auswertung der Pipes in Python), config.py wird nicht mehr ausgefuehrt (ast.literal_eval).\n'
     'Die Pruefpunkte, Schwellen und Texte sind unveraendert. /* secHard */\n\n'
     'sysBoot: laeuft der Dienst prepper-dashboard'),
    ("E02_imports",
     'import json\nimport re\n',
     'import ast\nimport json\nimport os\nimport re\n'),
    ("E03_imports2",
     'from pathlib import Path\n',
     'import pathlib\nfrom pathlib import Path\n'),
    ("E04_run",
     'def run(cmd, timeout=40):\n'
     '    try:\n'
     '        p = subprocess.run(\n'
     '            cmd, shell=True, capture_output=True, text=True, timeout=timeout\n'
     '        )\n'
     '        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()\n'
     '    except Exception as e:\n'
     '        return 1, "", str(e)\n',
     NEWRUN),
    ("E05_mesh_host",
     'def mesh_host():\n'
     '    try:\n'
     '        ns = {}\n'
     '        exec(open(BASE / "config.py").read(), ns)\n'
     '        return ns.get("MESHTASTIC_HOST", "192.168.178.141")\n'
     '    except Exception:\n'
     '        return "192.168.178.141"\n',
     NEWMESH),
    ("E06_compile",
     '        rc, _, err = run(\n'
     '            f"cd {BASE} && ./venv/bin/python -m py_compile dashboard.py"\n'
     '        )\n',
     '        rc, _, err = run(\n'
     '            [str(BASE / "venv" / "bin" / "python"), "-m", "py_compile", "dashboard.py"], cwd=str(BASE)\n'
     '        )\n'),
    ("E07_svc",
     '            rc, out, _ = run(f"systemctl is-active {svc}")\n',
     '            rc, out, _ = run(["systemctl", "is-active", svc])\n'),
    ("E08_nc",
     '        rc, _, _ = run(f"nc -z -w2 {host} 4403")\n',
     '        rc, _, _ = run(["nc", "-z", "-w2", host, "4403"])\n'),
    ("E09_disk",
     '        rc, out, _ = run("df -P / | awk \'NR==2{print $5}\'")\n',
     '        out = disk_used_text("/")\n'),
    ("E10_ram",
     '        rc, out, _ = run("awk \'/MemAvailable/{printf \\"%d\\", $2}\' /proc/meminfo")\n',
     '        out = mem_available_text()\n'),
    ("E11_temp",
     '        rc, out, _ = run("vcgencmd measure_temp 2>/dev/null | tr -d \\"temp=\'C\\"")\n',
     '        out = temp_text()\n'),
    ("E12_throttle",
     '        rc, out, _ = run("vcgencmd get_throttled 2>/dev/null")\n',
     '        rc, out, _ = run(["vcgencmd", "get_throttled"])\n'),
    ("E13_chrony",
     '        rc, out, _ = run("chronyc tracking 2>/dev/null | head -6")\n'
     '        items.append(item("chrony", rc == 0 and bool(out), "tracking OK" if out else "fail"))\n',
     '        out = chrony_text()\n'
     '        items.append(item("chrony", bool(out), "tracking OK" if out else "fail"))\n'),
    ("E14_apt",
     '        rc, out, _ = run(\n'
     '            "apt list --upgradable 2>/dev/null | grep -vc \'^Auflistung\' || true"\n'
     '        )\n',
     '        out = apt_upgradable_text()\n'),
    ("E15_selftest",
     'if __name__ == "__main__":\n'
     '    if "--selftest-fake" in sys.argv[1:]:\n'
     '        raise SystemExit(selftest_fake())\n',
     SELFTEST +
     'if __name__ == "__main__":\n'
     '    if "--selftest-fake" in sys.argv[1:]:\n'
     '        rc1 = selftest_fake()\n'
     '        raise SystemExit(rc1 or selftest_sechard())\n'),
]


def build(base, skip=()):
    out = base
    for name, old, new in EDITS:
        if name in skip:
            continue
        if out.count(old) != 1:
            raise SystemExit("Edit %s: %d Treffer (erwartet 1)" % (name, out.count(old)))
        out = out.replace(old, new)
    return out


if __name__ == "__main__":
    src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    pathlib.Path(sys.argv[2]).write_text(build(src), encoding="utf-8")
SEC_EDITS_EOF
EXPECT_EQ="1aabe36c297b709a530204c9653df78a01707a57b7da50388c039c58de29c01c"
cat > "$W/hcequiv.py" << 'SEC_EQ_EOF'
#!/usr/bin/env python3
"""hcequiv.py - Gleichwertigkeit health_check.py alt (Shell) gegen neu (Argumentlisten).
  sandbox ALT NEU          vollstaendige main() beider Fassungen mit gefalschten Programmen (PATH) und gefaelschtem Netz/Zeit; JSON-Pruefpunkte muessen gleich sein
  real ALT NEU PROJEKT     auf dem echten System, NUR LESEND: df, /proc/meminfo, vcgencmd, chronyc, systemctl is-active, apt list und
                           MESHTASTIC_HOST aus PROJEKT/config.py (alte Fassung fuehrt config.py aus wie bisher taeglich) - ohne nc, ohne HTTP, ohne Schreiben
"""
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import contextlib
import io

OLD_CMDS = {   # die Shell-Zeilen der alten Fassung (Referenz)
    "df": "df -P / | awk 'NR==2{print $5}'",
    "ram": "awk '/MemAvailable/{printf \"%d\", $2}' /proc/meminfo",
    "temp": "vcgencmd measure_temp 2>/dev/null | tr -d \"temp='C\"",
    "thr": "vcgencmd get_throttled 2>/dev/null",
    "chrony": "chronyc tracking 2>/dev/null | head -6",
    "apt": "apt list --upgradable 2>/dev/null | grep -vc '^Auflistung' || true",
}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def sh(path, body):
    pathlib.Path(path).write_text("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


SCEN = {
    "gut": dict(sysctl="active", nc=0, temp="temp=45.1'C", thr="throttled=0x0", chrony="ok", apt=3, df="42%", hdr="Auflistung..."),
    "kiwix aus, mesh weg": dict(sysctl="inactive:kiwix", nc=1, temp="temp=45.1'C", thr="throttled=0x0", chrony="ok", apt=0, df="42%", hdr="Auflistung..."),
    "kein vcgencmd/chronyc/apt": dict(sysctl="active", nc=0, temp=None, thr=None, chrony=None, apt=None, df="42%", hdr=""),
    "heiss, gedrosselt, Platte voll": dict(sysctl="active", nc=0, temp="temp=85.0'C", thr="throttled=0x50005", chrony="ok", apt=7, df="95%", hdr="Auflistung..."),
    "chronyc Fehlercode mit Text": dict(sysctl="active", nc=0, temp="temp=45.1'C", thr="throttled=0x0", chrony="rc1", apt=0, df="42%", hdr="Auflistung..."),
    "chronyc ohne Ausgabe": dict(sysctl="active", nc=0, temp="temp=45.1'C", thr="throttled=0x0", chrony="leer", apt=2, df="42%", hdr="Listing..."),
    "df ohne Prozent": dict(sysctl="active", nc=0, temp="komisch", thr="throttled=0x0", chrony="ok", apt=1, df="", hdr="Auflistung..."),
    "dashboard.py kaputt": dict(broken=True, sysctl="active", nc=0, temp="temp=45.1'C", thr="throttled=0x0", chrony="ok", apt=0, df="50%", hdr="Auflistung..."),
    "Dienst unbekannt": dict(sysctl="unknown", nc=0, temp="temp=45.1'C", thr="", chrony="ok", apt=0, df="99%", hdr="Auflistung..."),
}


def mkbin(d, s):
    d = pathlib.Path(d)
    d.mkdir(parents=True, exist_ok=True)
    for t in ("sh", "awk", "tr", "head", "grep", "cat"):
        p = shutil.which(t)
        if p:
            (d / t).symlink_to(p)
    if s["sysctl"].startswith("inactive:"):
        bad = s["sysctl"].split(":")[1]
        sh(d / "systemctl", 'if [ "$1" = is-active ] && [ "$2" = %s ]; then echo inactive; exit 3; fi; if [ "$1" = is-active ]; then echo active; exit 0; fi; exit 1' % bad)
    elif s["sysctl"] == "unknown":
        sh(d / "systemctl", 'echo unknown; exit 4')
    else:
        sh(d / "systemctl", 'if [ "$1" = is-active ]; then echo active; exit 0; fi; exit 1')
    sh(d / "nc", "exit %d" % s["nc"])
    if s["temp"] is not None:
        sh(d / "vcgencmd", 'if [ "$1" = measure_temp ]; then echo "%s"; elif [ "$1" = get_throttled ]; then echo "%s"; fi; exit 0' % (s["temp"], s["thr"]))
    if s["chrony"] == "ok":
        sh(d / "chronyc", 'printf "Reference ID    : C0A8B28B (x)\\nStratum         : 3\\nRef time (UTC)  : Sun Oct 25 07:00:00 2026\\nSystem time     : 0.000001 seconds fast\\nLast offset     : +0.000002 seconds\\nRMS offset      : 0.000010 seconds\\nFrequency       : 1.2 ppm slow\\nResidual freq   : 0.0\\n"; exit 0')
    elif s["chrony"] == "rc1":
        sh(d / "chronyc", 'echo "Reference ID    : 00000000 ()"; exit 1')
    elif s["chrony"] == "leer":
        sh(d / "chronyc", "exit 1")
    if s["apt"] is not None:
        lines = "".join('echo "pkg%d/stable 1.%d arm64 [upgradable from: 1.0]"; ' % (i, i) for i in range(s["apt"]))
        hdr = ('echo "%s"; ' % s["hdr"]) if s["hdr"] else ""
        sh(d / "apt", hdr + lines + "exit 0")
    sh(d / "df", 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/root 100000 42000 58000 %s /"; exit 0' % (s["df"] or ""))


class Net:
    class R:
        status = 200
    @staticmethod
    def urlopen(url, timeout=0):
        return Net.R()


def run_main(mod, base, bindir, s):
    mod.BASE = pathlib.Path(base)
    mod.OUT = mod.BASE / "health_status.json"
    mod.LOG = mod.BASE / "health_check.log"
    mod.dash_age_s = lambda: 99999.0
    mod.own_budget_s = lambda: 900.0
    mod.fetch_page = lambda p: 200 if p != "/pegel" or s["nc"] == 0 else 500
    mod.time.sleep = lambda x: None
    mod.urllib.request.urlopen = Net.urlopen
    old_path = os.environ.get("PATH")
    os.environ["PATH"] = str(bindir)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = mod.main()
    finally:
        os.environ["PATH"] = old_path
    d = json.loads((mod.BASE / "health_status.json").read_text())
    return rc, d


def sandbox(old_p, new_p):
    n = bad = 0
    for name, s in SCEN.items():
        res = []
        for tag, pth in (("alt", old_p), ("neu", new_p)):
            w = pathlib.Path(tempfile.mkdtemp(prefix="hceq-%s-" % tag))
            try:
                (w / "venv/bin").mkdir(parents=True)
                (w / "venv/bin/python").symlink_to(sys.executable)
                (w / "dashboard.py").write_text("def (:\n" if s.get("broken") else "x = 1\n")
                (w / "config.py").write_text('MESHTASTIC_HOST = "10.20.30.40"\n')
                mkbin(w / "bin", s)
                m = load(pth, "hc_" + tag)
                res.append(run_main(m, w, w / "bin", s))
            finally:
                shutil.rmtree(w, ignore_errors=True)
        (rc1, a), (rc2, b) = res
        ia, ib = a["items"], b["items"]
        diffs = []
        if rc1 != rc2:
            diffs.append("Rueckgabe %s/%s" % (rc1, rc2))
        if [i["id"] for i in ia] != [i["id"] for i in ib]:
            diffs.append("Pruefpunkte %s / %s" % ([i["id"] for i in ia], [i["id"] for i in ib]))
        for x, y in zip(ia, ib):
            if x["id"] == "ram":
                if x["ok"] != y["ok"] or x["msg"].split()[-2:] != y["msg"].split()[-2:]:
                    diffs.append("ram: %s / %s" % (x, y))
            elif x != y:
                diffs.append("%s / %s" % (x, y))
        for k in ("ok", "score", "max"):
            if a[k] != b[k]:
                diffs.append("%s: %s/%s" % (k, a[k], b[k]))
        n += 1
        if diffs:
            bad += 1
            print("  UNGLEICH [%s]: %s" % (name, "; ".join(diffs)[:400]))
    # mesh_host: gleiche Ergebnisse fuer einfache Texte
    cases = ['MESHTASTIC_HOST = "192.168.1.5"\n', 'A=1\nMESHTASTIC_HOST = "x.local"\nMESHTASTIC_HOST = "y.local"\n', 'PORT = 5000\n', 'MESHTASTIC_HOST = "fe80::1"\n',
             'def (:\n', '', 'MESHTASTIC_HOST = "10.1.2.3"  # kommentar\n']
    differ = [('MESHTASTIC_HOST = 5\n', "192.168.178.141"), ('MESHTASTIC_HOST = "1.2.3.4; reboot"\n', "192.168.178.141")]   # bewusst anders: alt gab den Wert ungeprueft weiter
    for c in cases:
        w = pathlib.Path(tempfile.mkdtemp(prefix="hceq-cfg-"))
        try:
            (w / "config.py").write_text(c)
            mo, mn = load(old_p, "hc_o"), load(new_p, "hc_n")
            mo.BASE = w
            mn.BASE = w
            mn.LOG = w / "l.log"
            n += 1
            ro = mo.mesh_host()
            rn = mn.mesh_host()
            if ro != rn:
                bad += 1
                print("  UNGLEICH mesh_host %r: alt %r neu %r" % (c[:40], ro, rn))
        finally:
            shutil.rmtree(w, ignore_errors=True)
    for c, want in differ:
        w = pathlib.Path(tempfile.mkdtemp(prefix="hceq-cfg-"))
        try:
            (w / "config.py").write_text(c)
            mn = load(new_p, "hc_n")
            mn.BASE = w
            mn.LOG = w / "l.log"
            n += 1
            if mn.mesh_host() != want:
                bad += 1
                print("  FALSCH mesh_host %r -> %r (erwartet %r)" % (c[:40], mn.mesh_host(), want))
        finally:
            shutil.rmtree(w, ignore_errors=True)
    print("hcequiv sandbox: %d Vergleiche (%d Szenarien mit voller main() + %d Konfigurationen + %d bewusst abweichende), %d Abweichungen" % (n, len(SCEN), len(cases), len(differ), bad))
    return 1 if bad else 0


def real(old_p, new_p, proj):
    mo, mn = load(old_p, "hc_o"), load(new_p, "hc_n")
    w = pathlib.Path(tempfile.mkdtemp(prefix="hceq-real-"))
    mo.BASE = pathlib.Path(proj)
    mo.LOG = w / "o.log"
    mn.BASE = pathlib.Path(proj)
    mn.LOG = w / "n.log"
    bad = n = 0
    def cmp(label, a, b, tol=None):
        nonlocal bad, n
        n += 1
        ok = (a == b) if tol is None else tol(a, b)
        print("  %s %-10s alt=%r neu=%r" % ("OK     " if ok else "UNGLEICH", label, a if len(str(a)) < 60 else str(a)[:57] + "...", b if len(str(b)) < 60 else str(b)[:57] + "..."))
        if not ok:
            bad += 1
    try:
        cmp("df", mo.run(OLD_CMDS["df"])[1], mn.disk_used_text("/"))
        cmp("ram_kB", mo.run(OLD_CMDS["ram"])[1], mn.mem_available_text(), lambda a, b: a.isdigit() and b.isdigit() and abs(int(a) - int(b)) <= max(20000, int(a) // 20))
        def tdiff(a, b):
            try:
                return abs(float(a) - float(b)) <= 3.0
            except ValueError:
                return a == b
        cmp("temp", mo.run(OLD_CMDS["temp"])[1], mn.temp_text(), tdiff)
        ro, oo, _ = mo.run(OLD_CMDS["thr"])
        rn, on, _ = mn.run(["vcgencmd", "get_throttled"])
        cmp("throttle", ((ro != 0), oo.replace(" ", "")[:30]), ((rn != 0), on.replace(" ", "")[:30]), lambda a, b: a[0] == b[0] and ("0x0" in a[1]) == ("0x0" in b[1]))
        co = mo.run(OLD_CMDS["chrony"])[1]
        cn = mn.chrony_text()
        cmp("chrony", [l.split(":")[0].strip() for l in co.splitlines()], [l.split(":")[0].strip() for l in cn.splitlines()])
        for svc in ("prepper-dashboard", "kiwix", "chrony"):
            ro, oo, _ = mo.run("systemctl is-active " + svc)
            rn, on, _ = mn.run(["systemctl", "is-active", svc])
            cmp("svc_" + svc[:8], (ro == 0, oo), (rn == 0, on))
        ao = mo.run(OLD_CMDS["apt"], timeout=40)[1]
        ao = (ao.strip().splitlines() or [""])[-1]
        an = mn.apt_upgradable_text()
        cmp("apt", ao, an)
        ho = mo.mesh_host()
        hn = mn.mesh_host(pathlib.Path(proj) / "config.py")
        cmp("mesh_host", ho, hn)    # nur Gleichheit gezeigt; der Wert selbst steht in config.py
    finally:
        shutil.rmtree(w, ignore_errors=True)
    print("hcequiv real: %d Vergleiche auf dem echten System (nur lesend), %d Abweichungen" % (n, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "sandbox":
        raise SystemExit(sandbox(a[1], a[2]))
    if a and a[0] == "real":
        raise SystemExit(real(a[1], a[2], a[3]))
    print(__doc__)
    raise SystemExit(2)
SEC_EQ_EOF
EXPECT_BASE="cc3949f1896ebbf36737c19d31e8e3ad2c4e764da7aca57cedafa0b901fa5c3f"
cat > "$W/base_health_check.py" << 'SEC_BASE_EOF'
#!/usr/bin/env python3
"""Health Report → health_status.json (nie systemctl restart). /* health3h */ /* sysBoot */

sysBoot: laeuft der Dienst prepper-dashboard noch keine 10 min (z. B. direkt nach dem Booten), wartet der Check,
bis er 10 min alt ist (nur so lange, wie die eigene Einheit erlaubt); reicht das nicht, bleibt der letzte Bericht stehen
(kein falsches PROBLEM 12/27). Seiten mit 15 s Zeitlimit, Fehlschlaege einmal nach 20 s nachgeprueft."""
import json
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
OUT = BASE / "health_status.json"
LOG = BASE / "health_check.log"
# Nav-Seiten (ohne API / Scanner / Decoder)
PAGES = [
    "/",
    "/energie",
    "/lokale-energie",
    "/speicher",
    "/umwelt",
    "/luft",
    "/pegel",
    "/adsb",
    "/zuhause",
    "/mesh",
    "/mesh2",
    "/news",
    "/funk",
    "/pi",
    "/medizin",
]

DASH_MIN_AGE_S = 600       # sysBoot
PAGE_TIMEOUT_S = 15        # sysBoot (vorher 8 s)
RETRY_PAUSE_S = 20         # sysBoot


def dash_age_s():
    """Sekunden seit Start von prepper-dashboard (None = unbekannt/inaktiv). # sysBoot"""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "ActiveEnterTimestampMonotonic", "-p", "ActiveState", "prepper-dashboard"],
                           capture_output=True, text=True, timeout=20)
        kv = dict(x.split("=", 1) for x in (p.stdout or "").splitlines() if "=" in x)
        if kv.get("ActiveState") != "active":
            return None
        us = int(kv.get("ActiveEnterTimestampMonotonic") or "0")
        if us <= 0:
            return None
        with open("/proc/uptime") as f:
            return max(0.0, float(f.read().split()[0]) - us / 1e6)
    except Exception:
        return None


def own_budget_s():
    """Wie lange darf diese Einheit laufen? (TimeoutStartUSec von prepper-health.service; infinity/unbekannt -> 900 s) # sysBoot"""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "TimeoutStartUSec", "--value", "prepper-health.service"],
                           capture_output=True, text=True, timeout=20)
        v = (p.stdout or "").strip()
        if not v or v == "infinity" or v == "0":
            return 900.0
        tot = 0.0
        for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*(min|ms|us|h|s)", v):
            tot += float(n) * {"h": 3600, "min": 60, "s": 1, "ms": 0.001, "us": 1e-6}[u]
        return tot if tot > 0 else 900.0
    except Exception:
        return 900.0


def wait_plan(age, budget):
    """-> (warten_s, ausfuehren). age None = Dienst nicht aktiv -> sofort pruefen (Fehler sind dann echt). # sysBoot"""
    if age is None or age >= DASH_MIN_AGE_S:
        return 0.0, True
    need = DASH_MIN_AGE_S - age + 5
    if need <= budget - 90:
        return need, True
    return 0.0, False


def fetch_page(p):
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:5000{p}", timeout=PAGE_TIMEOUT_S)
        return r.status
    except Exception:
        return 0


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")

def log(msg):
    line = f"[{now_str()}] {msg}"
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
        lines = LOG.read_text().splitlines()
        if len(lines) > 500:
            LOG.write_text("\n".join(lines[-350:]) + "\n")
    except Exception:
        pass

def run(cmd, timeout=40):
    try:
        p = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 1, "", str(e)

def item(id_, ok, msg):
    return {"id": id_, "ok": bool(ok), "msg": str(msg)[:120]}

def mesh_host():
    try:
        ns = {}
        exec(open(BASE / "config.py").read(), ns)
        return ns.get("MESHTASTIC_HOST", "192.168.178.141")
    except Exception:
        return "192.168.178.141"

def main():
    items = []
    try:
        age = dash_age_s()
        w, go = wait_plan(age, own_budget_s())
        if not go:
            log("uebersprungen: Dashboard erst %d s alt, Einheit darf nicht lange genug warten - letzter Bericht bleibt" % int(age or 0))
            return 0
        if w > 0:
            log("warte %d s: Dashboard erst %d s alt (Start laeuft)" % (int(w), int(age or 0)))
            time.sleep(w)
    except Exception as e:
        log(f"Startpruefung: {e}")
    try:
        rc, _, err = run(
            f"cd {BASE} && ./venv/bin/python -m py_compile dashboard.py"
        )
        items.append(
            item("compile", rc == 0, "Syntax OK" if rc == 0 else (err or "FAIL")[:80])
        )

        for svc in ("prepper-dashboard", "kiwix", "chrony"):
            rc, out, _ = run(f"systemctl is-active {svc}")
            items.append(item(f"svc_{svc}", rc == 0 and out == "active", out or "inactive"))

        codes = {p: fetch_page(p) for p in PAGES}
        bad = [p for p in PAGES if codes[p] != 200]
        if bad:
            time.sleep(RETRY_PAUSE_S)
            for p in bad:
                codes[p] = fetch_page(p)
            log("Seiten nachgeprueft: %d/%d jetzt ok" % (sum(1 for p in bad if codes[p] == 200), len(bad)))
        for p in PAGES:
            code = codes[p]
            items.append(item(f"page_{p}", code == 200, str(code)))

        try:
            code = urllib.request.urlopen("http://127.0.0.1:8080/", timeout=4).status
            k_ok = code == 200
        except Exception:
            k_ok, code = False, 0
        items.append(item("kiwix", k_ok, str(code)))

        host = mesh_host()
        rc, _, _ = run(f"nc -z -w2 {host} 4403")
        items.append(item("mesh", rc == 0, f"{host}:4403"))

        rc, out, _ = run("df -P / | awk 'NR==2{print $5}'")
        try:
            pct = int(out.replace("%", ""))
            items.append(item("disk", pct < 90, f"{pct} % belegt"))
        except Exception:
            items.append(item("disk", False, out or "n/a"))

        rc, out, _ = run("awk '/MemAvailable/{printf \"%d\", $2}' /proc/meminfo")
        try:
            avail_mb = int(out) // 1024
            items.append(item("ram", avail_mb >= 100, f"{avail_mb} MB frei"))
        except Exception:
            items.append(item("ram", False, "n/a"))

        rc, out, _ = run("vcgencmd measure_temp 2>/dev/null | tr -d \"temp='C\"")
        try:
            temp = float(out)
            items.append(item("temp", temp < 80, f"{temp:.1f} °C"))
        except Exception:
            items.append(item("temp", True, "n/a"))

        rc, out, _ = run("vcgencmd get_throttled 2>/dev/null")
        th_ok = "0x0" in out.replace(" ", "")
        items.append(item("throttle", th_ok or rc != 0, out or "n/a"))

        rc, out, _ = run("chronyc tracking 2>/dev/null | head -6")
        items.append(item("chrony", rc == 0 and bool(out), "tracking OK" if out else "fail"))

        rc, out, _ = run(
            "apt list --upgradable 2>/dev/null | grep -vc '^Auflistung' || true"
        )
        try:
            n = int(out.strip().splitlines()[-1])
        except Exception:
            n = -1
        items.append(item("apt", n == 0, f"{n} Updates" if n >= 0 else "n/a"))

    except Exception as e:
        log(f"ERROR {e}")
        items.append(item("internal", False, str(e)[:80]))

    critical = [i for i in items if i["id"] != "apt"]
    ok = all(i["ok"] for i in critical)
    data = {
        "ok": ok,
        "score": sum(1 for i in items if i["ok"]),
        "max": len(items),
        "at": now_str(),
        "items": items,
    }
    try:
        tmp = OUT.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        tmp.replace(OUT)
    except Exception as e:
        log(f"write JSON fail: {e}")
    log(f"done ok={ok} score={data['score']}/{data['max']}")
    return 0

def selftest_fake():
    """Warte-Logik mit Fakes (nichts wird geprueft). # sysBoot"""
    assert wait_plan(None, 900) == (0.0, True)
    assert wait_plan(700, 900) == (0.0, True)
    w, go = wait_plan(30, 900)
    assert go and 570 <= w <= 580
    assert wait_plan(30, 90) == (0.0, False)
    assert wait_plan(550, 160) == (55, True)
    print("health_check sysBoot selftest ok (wartet bis Dashboard 10 min alt, sonst letzter Bericht bleibt)")
    return 0


if __name__ == "__main__":
    if "--selftest-fake" in sys.argv[1:]:
        raise SystemExit(selftest_fake())
    raise SystemExit(main())
SEC_BASE_EOF
# ===================== gemeinsame Funktionen (Apply-Skripte der Serie "system") =====================
ERRLN=""; ERRCMD=""; PHASE=vorher
WD_N=80; WD_S=3; JN=48; JS=5; RD_N=40
if [[ "${SYSTEM_TEST:-}" == 1 ]]; then WD_N=${SY_WD_N:-80}; WD_S=${SY_WD_S:-3}; JN=${SY_JN:-48}; JS=${SY_JS:-5}; RD_N=${SY_RD_N:-40}; fi   # nur Sandbox-Test: kuerzere Wartezeiten
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
trap 'ec=$?; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
stop() { echo "STOP: $1 - nichts geaendert"; exit 1; }
s16() { sha256sum "$1" | cut -c1-16; }
code() { curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 40 "$1" || true; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || { VPY=python3; echo "HINWEIS venv-Python fehlt ($DASH_DIR/venv/bin/python) - Pruefung nur mit System-Python"; }
[[ -x "$SPY" ]] || SPY=python3
declare -A BSTATE
# check_base NAME PFAD "alt16 alt16 ..." NEU16 -> BSTATE[NAME]=alt|neu, sonst STOP mit Diff gegen die eingebettete Basis
check_base() {
  local n="$1" f="$2" olds="$3" new="$4" h o
  [[ -f "$f" ]] || stop "$n fehlt: $f"
  h=$(s16 "$f")
  if [[ "$h" == "$new" ]]; then BSTATE[$n]=neu; echo "OK Basis $n sha16 $h (schon die neue Fassung)"; return 0; fi
  for o in $olds; do
    if [[ "$h" == "$o" ]]; then BSTATE[$n]=alt; echo "OK Basis $n sha16 $h ($(wc -l < "$f") Zeilen, bekannt)"; return 0; fi
  done
  echo "Basis $n sha16 $h ($(wc -l < "$f") Zeilen) ist unbekannt (erwartet: $olds oder neu $new)"
  [[ -f "$W/base/$n" ]] && { echo "--- Unterschied zur erwarteten Basis (erste 60 Zeilen) ---"; diff -u "$W/base/$n" "$f" | head -60 || true; }
  stop "$n hat einen unbekannten Stand"
}
prune_bak() { { ls -1t "$1.bak-$NAME-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done; }
verify_payloads() { # PAYLOADS=("datei:VAR" ...) -> EXPECT_<VAR> enthaelt die erwartete sha256
  local e n v
  for e in "${PAYLOADS[@]}"; do
    n="${e%%:*}"; v="EXPECT_${e##*:}"; [[ -f "$W/$n" ]] || stop "Nutzlast $n fehlt"
    [[ "$(sha256sum "$W/$n" | cut -d' ' -f1)" == "${!v}" ]] || stop "Nutzlast $n: Pruefsumme stimmt nicht (Skript veraendert oder beschaedigt)"
  done
  echo "OK ${#PAYLOADS[@]} eingebettete Dateien: sha256 stimmt"
}
pycomp() { # DATEI... : System-Python und venv-Python, ohne Bytecode ins Ziel zu schreiben
  local f py
  for py in "$SPY" "$VPY"; do
    for f in "$@"; do "$py" - "$f" << 'PYC' || return 1
import sys
src = open(sys.argv[1], encoding="utf-8").read()
import warnings
with warnings.catch_warnings():
    warnings.simplefilter("error")
    compile(src, sys.argv[1], "exec")
PYC
    done
  done
}
sqlite_snapshot() { # QUELLE ZIEL: Backup-Schnittstelle, nur lesend gelesen, integrity_check der Kopie
  "$SPY" - "$1" "$2" << 'PYE'
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=20)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
n = dst.execute("PRAGMA integrity_check").fetchone()[0]
assert n == "ok", n
dst.close(); src.close()
PYE
}
dash_get_codes() { # ARRAYNAME: Codes aller 26 Seiten/APIs
  local -n _arr="$1"; local p
  for p in "${PAGES[@]}" "${APIS[@]}"; do _arr[$p]=$(code "$B$p"); done
}
wait_dash() { # wartet auf aktiv + HTTP 200 (max 240 s)
  local i
  for i in $(seq 1 "$WD_N"); do sleep "$WD_S"; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done
  return 1
}
wait_ready() { # wartet, bis die Startseite "Dashboard startet" weg ist (max 200 s) - nur Hinweis
  local i p ok2
  for i in $(seq 1 "$RD_N"); do
    ok2=1; for p in /umwelt /energie /; do "${CURL[@]}" "$B$p" -o "$W/pg.html" || true; grep -q "<title>Dashboard startet" "$W/pg.html" 2>/dev/null && ok2=0; done
    [[ "$ok2" == 1 ]] && return 0
    sleep 5
  done
  return 1
}
smoke_all() { # vergleicht mit CODE0; Rueckgabe 1 bei Abweichung
  declare -A c1; local p bad=0 n=0
  dash_get_codes c1
  for p in "${PAGES[@]}" "${APIS[@]}"; do
    n=$((n + 1))
    if [[ "${CODE0[$p]}" == 200 && "${c1[$p]}" != 200 ]]; then echo "  FEHLER $p = ${c1[$p]} (vorher 200)"; bad=1; fi
    [[ "${CODE0[$p]}" != 200 ]] && echo "  HINWEIS $p war vorher schon ${CODE0[$p]} (jetzt ${c1[$p]})"
  done
  [[ "$bad" == 0 ]] && echo "OK Rauchtest: $n Seiten/APIs wie vorher ($(for p in "${PAGES[@]}" "${APIS[@]}"; do echo -n "$p=${c1[$p]} "; done | cut -c1-900))"
  return $bad
}
write_atomic() { # QUELLE ZIEL MODUS
  cp "$1" "$2.new.$$" && chmod "$3" "$2.new.$$" && mv -f "$2.new.$$" "$2"
}
PAYLOADS=(health_check.py:HC lage_xml.py:XML lage_reqs.py:REQS requirements.txt.vorlage:VORL guard_sechard.py:GUARD edits_sechard.py:EDITS hcequiv.py:EQ base_health_check.py:BASE)
verify_payloads
cp "$W/base_health_check.py" "$W/base/health_check.py"
# ---------- 1) Zustand vorher (nur lesend) ----------
[[ -d "$DASH_DIR" ]] || stop "Projektordner fehlt: $DASH_DIR"
[[ "$(stat -c %U "$DASH_DIR")" == "$(id -un)" ]] || stop "$DASH_DIR gehoert $(stat -c %U "$DASH_DIR"), du bist $(id -un): bitte als Benutzer $(stat -c %U "$DASH_DIR") ausfuehren (nicht mit sudo/root, sonst entstehen root-eigene Dateien)"
a=$(systemctl is-active prepper-dashboard 2>/dev/null || true); [[ "$a" == active ]] || stop "Dienst prepper-dashboard ist nicht aktiv ($a)"
check_base health_check.py "$HCF" "$KNOWN_HC16" "$NEW_HC16"
declare -A SHA0
for x in dashboard.py prepper_sdr.py sdr_manager.py prepper_docs.py mesh_router.py lagegeo.py database.py config.py; do [[ -f "$DASH_DIR/$x" ]] && SHA0[$x]=$(s16 "$DASH_DIR/$x"); done
declare -A CODE0; dash_get_codes CODE0
n200=0; for p in "${PAGES[@]}" "${APIS[@]}"; do [[ "${CODE0[$p]}" == 200 ]] && n200=$((n200 + 1)); done
echo "vorher HTTP: $n200 von $(( ${#PAGES[@]} + ${#APIS[@]} )) Seiten/APIs = 200 ($(for p in "${PAGES[@]}" "${APIS[@]}"; do echo -n "$p=${CODE0[$p]} "; done | cut -c1-700))"
[[ "$n200" -ge 1 ]] || stop "das Dashboard antwortet nicht (Port $PORT)"
# ---------- 2) Pruefungen der Nutzlast (Sandbox, nichts Echtes angefasst) ----------
"$SPY" "$W/edits_sechard.py" "$W/base/health_check.py" "$W/rebuilt.py" || stop "Aufbau aus der Basis misslungen"
cmp -s "$W/rebuilt.py" "$W/health_check.py" && echo "OK die eingebettete health_check.py ist byte-genau das Ergebnis der geprueften Edits auf der Basis" || stop "eingebettete health_check.py ungleich Edits(Basis)"
"$SPY" "$W/guard_sechard.py" check "$W/health_check.py" "$W/lage_xml.py" "$W/lage_reqs.py" "$W/base/health_check.py" || stop "Guard hat die Nutzlast beanstandet"
"$SPY" "$W/guard_sechard.py" mutate "$W/base/health_check.py" "$W/edits_sechard.py" "$W/lage_xml.py" "$W/lage_reqs.py" || stop "Mutationstest: eine Mutation wurde uebersehen"
pycomp "$W/health_check.py" "$W/lage_xml.py" "$W/lage_reqs.py" "$W/guard_sechard.py" "$W/edits_sechard.py" "$W/hcequiv.py" || stop "py_compile mit Warnung/Fehler"
echo "OK py_compile ohne Warnung (System-Python $("$SPY" -V 2>&1), venv-Python $("$VPY" -V 2>&1))"
for py in "$SPY" "$VPY"; do
  rm -rf "$W/sbx" && mkdir -p "$W/sbx" && cp "$W/health_check.py" "$W/lage_xml.py" "$W/sbx/"
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$py" health_check.py --selftest-fake > "$W/st.out" 2>&1) || { tail -8 "$W/st.out"; stop "Selbsttest health_check.py ($py) fehlgeschlagen"; }
  grep -q "health_check secHard selftest ok" "$W/st.out" || { tail -5 "$W/st.out"; stop "Selbsttest secHard meldet nicht ok"; }
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$py" lage_xml.py > "$W/st2.out" 2>&1) || { tail -8 "$W/st2.out"; stop "Selbsttest lage_xml.py ($py) fehlgeschlagen"; }
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$py" -c "import sys; sys.modules['defusedxml'] = None; import lage_xml; assert lage_xml.HARD is False; print(lage_xml.selftest())" > "$W/st3.out" 2>&1) || { tail -8 "$W/st3.out"; stop "Selbsttest lage_xml.py ohne defusedxml ($py) fehlgeschlagen"; }
  grep -q "nur Rueckfall" "$W/st3.out" || stop "lage_xml.py ohne defusedxml: Rueckfall nicht bestaetigt"
  DXV=$(PYTHONDONTWRITEBYTECODE=1 "$py" -c "import defusedxml; print(defusedxml.__version__)" 2>/dev/null || true)
  echo "OK Selbsttests mit $("$py" -V 2>&1): health_check (sysBoot + secHard), lage_xml mit und ohne defusedxml (defusedxml in diesem Python: ${DXV:-nein})"
done
# Werkzeug lage_reqs in einem Sandbox-Projekt (nur lesend, installiert nichts)
rm -rf "$W/sbx" && mkdir -p "$W/sbx/tools" "$W/sbx/venv/bin" && cp "$W/lage_reqs.py" "$W/sbx/tools/"
ln -s "$(command -v python3)" "$W/sbx/venv/bin/python"
printf 'import os\ntry:\n    import psutil\nexcept ImportError:\n    pass\nimport sys\nimport nichtvorhandenespaket\n' > "$W/sbx/dashboard.py"
rc=0; (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$SPY" tools/lage_reqs.py check > "$W/rq.out" 2>&1) || rc=$?
grep -q "FEHLT  nichtvorhandenespaket" "$W/rq.out" && grep -q "Es wurde nichts installiert" "$W/rq.out" || { cat "$W/rq.out"; stop "lage_reqs check (Sandbox) liefert nicht das Erwartete"; }
(cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$SPY" tools/lage_reqs.py vorlage > "$W/rq2.out" 2>&1) || { cat "$W/rq2.out"; stop "lage_reqs vorlage (Sandbox) fehlgeschlagen"; }
grep -q "HIER-HASH-EINTRAGEN" "$W/rq2.out" || stop "lage_reqs vorlage ohne Platzhalter-Kennzeichnung"
rc=0; (cd "$W/sbx" && "$SPY" tools/lage_reqs.py hashes > "$W/rq3.out" 2>&1) || rc=$?
[[ "$rc" == 2 ]] || stop "lage_reqs hashes ohne --netz muss mit Exit 2 abbrechen (Exit $rc)"
(cd "$W/sbx" && "$SPY" tools/lage_reqs.py vorlage --out "$W/sbx/r.neu" > /dev/null 2>&1 && ! "$SPY" tools/lage_reqs.py vorlage --out "$W/sbx/r.neu" > /dev/null 2>&1) || stop "lage_reqs --out: ueberschreibt oder schreibt nicht"
[[ -z "$(ls "$W/sbx" | grep -v -E '^(tools|venv|dashboard.py|r.neu)$' || true)" ]] || stop "lage_reqs hat unerwartete Dateien angelegt"
echo "OK tools/lage_reqs.py in der Sandbox: check, vorlage (Platzhalter gekennzeichnet), hashes ohne --netz bricht ab, --out ueberschreibt nie"
# Vergleich alt/neu mit gefaelschten Programmen (volle main(), 9 Szenarien) mit beiden Pythons
for py in "$SPY" "$VPY"; do
  PYTHONDONTWRITEBYTECODE=1 "$py" "$W/hcequiv.py" sandbox "$W/base/health_check.py" "$W/health_check.py" > "$W/eq.out" 2>&1 || { tail -12 "$W/eq.out"; stop "Vergleich alt/neu (Fakes, $py) hat Abweichungen"; }
  echo "OK $(tail -1 "$W/eq.out") [$("$py" -V 2>&1)]"
done
# Vergleich auf dem ECHTEN System (nur lesend). ALT = die aktuell installierte Fassung (oder die eingebettete Basis, wenn schon neu)
OLDHC="$HCF"; [[ "${BSTATE[health_check.py]}" == neu ]] && OLDHC="$W/base/health_check.py"
nice -n 19 env PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/hcequiv.py" real "$OLDHC" "$W/health_check.py" "$DASH_DIR" > "$W/eqr.out" 2>&1 || { cat "$W/eqr.out" | cut -c1-200; stop "Vergleich alt/neu auf dem echten System hat Abweichungen (nichts geaendert)"; }
cat "$W/eqr.out" | cut -c1-160 | sed 's/^/    /'
echo "OK echtes System: alte Shell-Zeilen und neue Argumentlisten liefern dasselbe (nur lesend; ohne nc, ohne HTTP, ohne Schreiben)"
# ---------- venv-Bestand (nur lesend): psutil, defusedxml ----------
echo "venv-Bestand (nur lesend, nichts wird installiert):"
RQ=0
if [[ -x "$DASH_DIR/venv/bin/python" ]]; then
  mkdir -p "$W/rqp/tools"; cp "$W/lage_reqs.py" "$W/rqp/tools/"
  nice -n 19 env PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/rqp/tools/lage_reqs.py" check --projekt "$DASH_DIR" --venv "$DASH_DIR/venv" > "$W/rqr.out" 2>&1 || RQ=$?
  cut -c1-170 "$W/rqr.out" | sed 's/^/    /'
  PSI=$(PYTHONDONTWRITEBYTECODE=1 "$DASH_DIR/venv/bin/python" -c "import psutil; print(psutil.__version__)" 2>/dev/null || true)
  [[ -n "$PSI" ]] && echo "  psutil im venv: JA ($PSI) - das Laufzeit-pip-install in dashboard.py (Zeilen 11-15) wird mit diesem Python nie ausgefuehrt" || echo "  psutil im venv: NEIN - dashboard.py wuerde beim Start pip install psutil ausfuehren (SEC-10); bitte melden, bevor dashboard.py geaendert wird"
  DXI=$(PYTHONDONTWRITEBYTECODE=1 "$DASH_DIR/venv/bin/python" -c "import defusedxml; print(defusedxml.__version__)" 2>/dev/null || true)
  [[ -n "$DXI" ]] && echo "  defusedxml im venv: JA ($DXI) - lage_xml.py nutzt es" || echo "  defusedxml im venv: NEIN - lage_xml.py faellt auf xml.etree mit Groessenlimit zurueck (ehrlich gemeldet); Installation ist ein eigener, manueller Schritt (siehe Bericht)"
else
  echo "  venv-Python fehlt ($DASH_DIR/venv/bin/python) - nicht ermittelbar"
fi
if [[ "$OPT" == "trocken" ]]; then
  echo "TROCKENLAUF FERTIG: alle Pruefungen ok, es wurde nichts geaendert (kein sudo, kein Neustart, nichts installiert). Zum Installieren ohne 'trocken' aufrufen."
  exit 0
fi
# ---------- 3) Installieren (kein sudo, kein Neustart: health_check.py laeuft als eigene Einheit/Timer und wird beim naechsten Lauf neu gelesen) ----------
declare -A NEED=()
same() { [[ -f "$2" ]] && cmp -s "$1" "$2"; }
same "$W/health_check.py" "$HCF" || NEED[hc]=1
same "$W/lage_xml.py" "$XMLF" || NEED[xml]=1
same "$W/lage_reqs.py" "$REQF" || NEED[reqs]=1
same "$W/requirements.txt.vorlage" "$VORF" || NEED[vorl]=1
if [[ "${#NEED[@]}" == 0 ]]; then
  echo "OK secHard schon installiert (health_check.py, lage_xml.py, tools/lage_reqs.py, requirements.txt.vorlage) - keine Aenderung"
else
  trap '' INT
  PHASE=Installation
  declare -A WAS
  FILES=("hc:$HCF" "xml:$XMLF" "reqs:$REQF" "vorl:$VORF")
  rb() {
    set +e +o pipefail
    trap - ERR
    echo "ROLLBACK: $1"
    local e k f
    for e in "${FILES[@]}"; do
      k="${e%%:*}"; f="${e#*:}"
      [[ -n "${NEED[$k]:-}" ]] || continue
      if [[ "${WAS[$k]:-0}" == 1 ]]; then [[ -f "$f.bak-$NAME-$TS" ]] && cp -a "$f.bak-$NAME-$TS" "$f.rb" && mv -f "$f.rb" "$f"; else rm -f "$f" "$f.new."*; fi
    done
    [[ -f "$HCF.bak-$NAME-$TS" ]] && { cmp -s "$HCF" "$HCF.bak-$NAME-$TS" && echo "  health_check.py = Sicherung ($(s16 "$HCF"))" || echo "  WARNUNG health_check.py ungleich Sicherung"; }
    echo "alter Stand wieder aktiv: dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
  }
  mkdir -p "$TOOLD" || { echo "FEHLER: $TOOLD nicht anlegbar"; exit 1; }
  for e in "${FILES[@]}"; do
    k="${e%%:*}"; f="${e#*:}"
    WAS[$k]=0; [[ -f "$f" ]] && WAS[$k]=1
    if [[ -n "${NEED[$k]:-}" && "${WAS[$k]}" == 1 ]]; then cp -a "$f" "$f.bak-$NAME-$TS"; prune_bak "$f"; fi
  done
  MODE_HC=644; [[ -f "$HCF.bak-$NAME-$TS" ]] && MODE_HC=$(stat -c %a "$HCF.bak-$NAME-$TS")
  [[ -n "${NEED[hc]:-}" ]] && { write_atomic "$W/health_check.py" "$HCF" "$MODE_HC" || { rb "health_check.py nicht installierbar"; exit 1; }; }
  [[ -n "${NEED[xml]:-}" ]] && { write_atomic "$W/lage_xml.py" "$XMLF" 644 || { rb "lage_xml.py nicht installierbar"; exit 1; }; }
  [[ -n "${NEED[reqs]:-}" ]] && { write_atomic "$W/lage_reqs.py" "$REQF" 755 || { rb "tools/lage_reqs.py nicht installierbar"; exit 1; }; }
  [[ -n "${NEED[vorl]:-}" ]] && { write_atomic "$W/requirements.txt.vorlage" "$VORF" 644 || { rb "requirements.txt.vorlage nicht installierbar"; exit 1; }; }
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-$NAME-$TS, behalten: letzte $KEEP_LAST)"
  # Nachpruefung mit den INSTALLIERTEN Dateien
  PHASE=Pruefung
  [[ "${SYSTEM_TEST:-}" == 1 && "${SY_BREAK:-}" == post ]] && echo "# Testfehler" >> "$HCF"    # nur Sandbox-Test: Rollback-Pfad
  for f in "$HCF" "$XMLF" "$REQF"; do cmp -s "$W/$(basename "$f")" "$f" || { rb "$(basename "$f") im Ziel ungleich Nutzlast"; exit 1; }; done
  (cd "$DASH_DIR" && PYTHONDONTWRITEBYTECODE=1 "$VPY" "$HCF" --selftest-fake > "$W/st4.out" 2>&1) && grep -q "secHard selftest ok" "$W/st4.out" || { tail -5 "$W/st4.out"; rb "Selbsttest der installierten health_check.py fehlgeschlagen"; exit 1; }
  (cd "$DASH_DIR" && PYTHONDONTWRITEBYTECODE=1 "$VPY" "$XMLF" > "$W/st5.out" 2>&1) || { tail -5 "$W/st5.out"; rb "Selbsttest der installierten lage_xml.py fehlgeschlagen"; exit 1; }
  pycomp "$HCF" "$XMLF" "$REQF" || { rb "py_compile der installierten Dateien mit Warnung/Fehler"; exit 1; }
  nice -n 19 env PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/hcequiv.py" real "$W/base/health_check.py" "$HCF" "$DASH_DIR" > "$W/eqr2.out" 2>&1 || { tail -5 "$W/eqr2.out" | cut -c1-200; rb "Vergleich alt/neu mit der installierten Datei hat Abweichungen"; exit 1; }
  echo "OK installierte Dateien: Selbsttests, py_compile, Vergleich alt/neu auf dem echten System"
fi
PHASE=Pruefung
type rb >/dev/null 2>&1 || rb() { echo "FEHLER: $1"; }
[[ "${SYSTEM_TEST:-}" == 1 && "${SY_BREAK:-}" == dash ]] && kill "$(cat "$FAKE_ST/dash.pid")" 2>/dev/null    # nur Sandbox-Test: Rollback-Pfad nach dem Rauchtest
sleep 2
smoke_all || { rb "Rauchtest: eine Seite/API antwortet nicht mehr wie vorher"; exit 1; }
systemctl is-active --quiet prepper-dashboard || { rb "prepper-dashboard laeuft nicht mehr"; exit 1; }
for x in "${!SHA0[@]}"; do [[ "$(s16 "$DASH_DIR/$x")" == "${SHA0[$x]}" ]] && echo "OK $x unveraendert (${SHA0[$x]})" || { rb "$x hat sich veraendert"; exit 1; }; done
echo "OK guards: secHard(health_check.py)=$(grep -c 'secHard (SEC-09)' "$HCF" || true)"
echo
echo "=== secHard FERTIG ($COMMIT_ARG) ==="
for x in "$HCF" "$XMLF" "$REQF" "$VORF"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
[[ -f "$HCF.bak-$NAME-$TS" ]] && echo "Rueckgaengig: cp -p $HCF.bak-$NAME-$TS $HCF   (kein Neustart noetig; neue Dateien optional entfernen: rm $XMLF $REQF $VORF)"
echo "health_check.py laeuft als eigene Einheit/Timer: die neue Fassung wird beim naechsten Lauf benutzt. Pruefen (nur lesend): python3 $REQF check"
