#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-haerten-a. Mesh-Escape, Zubringer-Schloss, lan_ok, fullcheck-info."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

PAYLOAD = json.loads(r"""{"A": [["lage_pages.py", "  function row(it){", "  function esc(s){\n    return String(s == null ? \"\" : s).replace(/[&<>\"']/g, function(c){\n      return {\"&\":\"&amp;\",\"<\":\"&lt;\",\">\":\"&gt;\",'\"':\"&quot;\",\"'\":\"&#39;\"}[c];\n    });\n  }\n  function row(it){", 2], ["lage_pages.py", "    var who = it.me ? \"\" : '<div class=\"from\" style=\"opacity:.75\">' + (it.from || \"\") + \"</div>\";\n    return who + '<div class=\"' + cls + '\">' + (it.text || \"\") + \"</div>\"\n      + (meta.length ? '<div class=\"meta\">' + meta.join(\" · \") + \"</div>\" : \"\");", "    var who = it.me ? \"\" : '<div class=\"from\" style=\"opacity:.75\">' + esc(it.from || \"\") + \"</div>\";\n    return who + '<div class=\"' + cls + '\">' + esc(it.text || \"\") + \"</div>\"\n      + (meta.length ? '<div class=\"meta\">' + meta.map(esc).join(\" · \") + \"</div>\" : \"\");", 2], ["flugfunk.py", "def lan_ok(ip):\n    if not ip:\n        return True\n", "def lan_ok(ip):\n    if not ip or not str(ip).strip():\n        return False\n", 1], ["flugfunk.py", "def icecast_sicher(base):\n    \"\"\"Stille in Pausen, Neustart wenn der Relay tot ist oder der Mount nicht 200 liefert.\"\"\"\n    pw = os.path.join(base, \"icecast-flugfunk.pw\")\n", "_ICE_LOCK = threading.Lock()\n\n\ndef icecast_sicher(base):\n    \"\"\"Ein Lauf gleichzeitig. Ist der Zubringer schon dran, wartet der naechste Takt.\"\"\"\n    if not _ICE_LOCK.acquire(blocking=False):\n        return\n    try:\n        _icecast_sicher_innen(base)\n    finally:\n        _ICE_LOCK.release()\n\n\ndef _icecast_sicher_innen(base):\n    pw = os.path.join(base, \"icecast-flugfunk.pw\")\n", 1], ["flugfunk.py", "                if now >= naechstes_aufraeumen:\n                    aufraeumen(base, now)\n                    naechstes_aufraeumen = now + 600\n                icecast_sicher(base)\n                self._eine_transkription(base, now)\n", "                if now >= naechstes_aufraeumen:\n                    aufraeumen(base, now)\n                    naechstes_aufraeumen = now + 600\n                self._eine_transkription(base, now)\n", 1], ["flugfunk.py", "    umgebung = os.environ.copy()\n    umgebung[\"FLUGFUNK_PW_FILE\"] = pw\n    relay = subprocess.Popen(\n        [__import__(\"sys\").executable, \"-c\", _ICE_RELAY],\n        stdin=quelle, stdout=subprocess.DEVNULL,\n        stderr=open(os.path.join(base, \"flugfunk-icecast.log\"), \"ab\"),\n        env=umgebung, start_new_session=True,\n    )\n", "    umgebung = {\"PATH\": os.environ.get(\"PATH\", \"/usr/bin:/bin\"), \"FLUGFUNK_PW_FILE\": pw}\n    log = open(os.path.join(base, \"flugfunk-icecast.log\"), \"ab\")\n    try:\n        relay = subprocess.Popen(\n            [__import__(\"sys\").executable, \"-c\", _ICE_RELAY],\n            stdin=quelle, stdout=subprocess.DEVNULL,\n            stderr=log,\n            env=umgebung, start_new_session=True,\n        )\n    finally:\n        log.close()\n", 1], ["flugfunk.py", "    assert lan_ok(\"192.168.178.20\") and lan_ok(\"127.0.0.1\") and lan_ok(\"::1\") and lan_ok(\"100.64.1.1\")\n    assert not lan_ok(\"8.8.8.8\") and not lan_ok(\"1.1.1.1\")\n", "    assert lan_ok(\"192.168.178.20\") and lan_ok(\"127.0.0.1\") and lan_ok(\"::1\") and lan_ok(\"100.64.1.1\")\n    assert not lan_ok(\"8.8.8.8\") and not lan_ok(\"1.1.1.1\") and not lan_ok(\"\") and not lan_ok(None) and not lan_ok(\"xyz\")\n", 1], ["flugfunk.py", "  if(live) live.addEventListener('click',function(){\n    if(!audio) return;\n    liveAn=true;\n    var gefallen=false;\n    function fallback(){\n      if(gefallen) return;\n      gefallen=true;\n      audio.onerror=null;\n      audio.src='/api/flugfunk/stream?t='+Date.now();\n      audio.play();\n    }\n    audio.onerror=fallback;\n    audio.src='/flugfunk?t='+Date.now();\n    var p=audio.play();\n    if(p&&p.catch) p.catch(fallback);\n  });\n  if(audio) audio.addEventListener('ended',function(){\n    if(!liveAn) return;\n    audio.src='/flugfunk?t='+Date.now();\n    audio.play();\n  });\n", "  if(live) live.addEventListener('click',function(){\n    if(!audio) return;\n    liveAn=true;\n    var gefallen=false;\n    var wecker=0;\n    function fallback(){\n      if(gefallen) return;\n      gefallen=true;\n      if(wecker) clearTimeout(wecker);\n      audio.onerror=null;\n      audio.onstalled=null;\n      audio.onemptied=null;\n      audio.src='/api/flugfunk/stream?t='+Date.now();\n      var p2=audio.play();\n      if(p2&&p2.catch) p2.catch(function(){});\n    }\n    function haengt(){\n      if(audio.readyState>=2) return;\n      fallback();\n    }\n    audio.onerror=fallback;\n    audio.onstalled=haengt;\n    audio.onemptied=haengt;\n    wecker=setTimeout(haengt, 5000);\n    audio.onplaying=function(){ if(wecker) clearTimeout(wecker); };\n    audio.src='/flugfunk?t='+Date.now();\n    var p=audio.play();\n    if(p&&p.catch) p.catch(fallback);\n  });\n  if(audio) audio.addEventListener('ended',function(){\n    if(!liveAn) return;\n    audio.src='/api/flugfunk/stream?t='+Date.now();\n    var p3=audio.play();\n    if(p3&&p3.catch) p3.catch(function(){});\n  });\n", 1], ["flugfunk.py", "def icecast_response(base):\n    \"\"\"Mount /flugfunk nur im LAN. Icecast bleibt auf 127.0.0.1.\"\"\"\n    from flask import Response, abort\n    import urllib.request\n    if not lan_ok(_client()):\n        abort(403)\n    try:\n        quelle = urllib.request.urlopen(\"http://127.0.0.1:8000/flugfunk\", timeout=3)\n    except Exception:\n        abort(404)\n    def stueck():\n        try:\n            while True:\n                block = quelle.read(2048)\n                if not block:\n                    break\n                yield block\n        finally:\n            quelle.close()\n    return Response(stueck(), mimetype=\"audio/mpeg\", headers={\"Cache-Control\": \"no-store\"})\n", "_ICECAST = (\"127.0.0.1\", 8000)\n\n\ndef icecast_response(base):\n    \"\"\"Mount /flugfunk nur im LAN. Status erst nach dem ersten Audioblock, sonst 503.\"\"\"\n    from flask import Response, abort\n    import socket\n    if not lan_ok(_client()):\n        abort(403)\n    sock = None\n    try:\n        sock = socket.create_connection(_ICECAST, 3)\n        sock.settimeout(5)\n        sock.sendall(b\"GET /flugfunk HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nIcy-MetaData: 0\\r\\nConnection: close\\r\\n\\r\\n\")\n        kopf = b\"\"\n        while b\"\\r\\n\\r\\n\" not in kopf and len(kopf) < 8192:\n            teil = sock.recv(1024)\n            if not teil:\n                break\n            kopf += teil\n        teile = kopf.split(b\"\\r\\n\\r\\n\", 1)\n        status = teile[0].split(b\"\\r\\n\", 1)[0] if teile else b\"\"\n        rest = teile[1] if len(teile) > 1 else b\"\"\n        if b\"200\" not in status[:24]:\n            raise OSError(\"status\")\n        if not rest:\n            rest = sock.recv(4096)\n        if not rest:\n            raise OSError(\"leer\")\n    except Exception:\n        if sock is not None:\n            try:\n                sock.close()\n            except OSError:\n                pass\n        abort(503)\n    def stueck(erst=rest, verbindung=sock):\n        try:\n            yield erst\n            verbindung.settimeout(15)\n            while True:\n                block = verbindung.recv(4096)\n                if not block:\n                    break\n                yield block\n        finally:\n            verbindung.close()\n    antwort = Response(stueck(), mimetype=\"audio/mpeg\")\n    antwort.headers[\"Cache-Control\"] = \"no-store\"\n    antwort.headers[\"X-Accel-Buffering\"] = \"no\"\n    return antwort\n", 1], ["fullcheck.sh", "  info() { :; }\n  CODE=\"$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -r 0-0 http://127.0.0.1:8000/flugfunk || true)\"\n  if [[ \"$CODE\" == \"200\" ]]; then ok \"Icecast /flugfunk\" \"Mount live\"\n  elif systemctl is-active --quiet prepper-icecast; then warn \"Icecast /flugfunk\" \"HTTP $CODE\" \"Mount nicht 200\"\n  else info \"Icecast /flugfunk\" \"Dienst nicht aktiv\"; fi\n", "  CODE=\"$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -r 0-0 http://127.0.0.1:8000/flugfunk || true)\"\n  if [[ \"$CODE\" == \"200\" ]]; then ok \"Icecast /flugfunk\" \"Mount live\"\n  elif systemctl is-active --quiet prepper-icecast; then warn \"Icecast /flugfunk\" \"HTTP $CODE\" \"Mount nicht 200\"\n  else :; fi\n", 1]], "FEST_A": {"lage_pages.py": {"sha256": "e9ea014b5a4ff1214fc605be32c9b813fa1eee24c6394f83bdfe9108d43e5784", "sha16": "e9ea014b5a4ff121", "bytes": 230936}, "flugfunk.py": {"sha256": "4f550e1a039a2f36dcef471027eda4eb3981f9d1f9097c3ca79915876087ea5f", "sha16": "4f550e1a039a2f36", "bytes": 97536}, "fullcheck.sh": {"sha256": "dd156c8a6b0dd29b5c48f1c5ce7ff497002c0f5c915bfc5cee574ea3917afca0", "sha16": "dd156c8a6b0dd29b", "bytes": 99269}}}""")
SCHLUESSEL = "A"
SCHREIBEN = ["lage_pages.py", "flugfunk.py", "fullcheck.sh"]
PRUEFEN = ["lage_pages.py", "flugfunk.py", "fullcheck.sh"]
DIENSTE = ["prepper-sdr", "prepper-dashboard"]
BASIS = "/home/fmg/prepper-dashboard"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sperre(minute):
    minute = int(minute)
    return minute >= 40 or minute <= 4


def berlin_minute():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin")).minute
    return datetime.now().minute


def ersetze(text, alt, neu, name, n):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def sichere(path, kennung):
    if not os.path.isfile(path):
        return
    for i in (3, 2, 1):
        ziel = "%s.bak-%s-%s" % (path, kennung, i)
        if i == 1:
            shutil.copy2(path, ziel)
        else:
            vor = "%s.bak-%s-%s" % (path, kennung, i - 1)
            if os.path.isfile(vor):
                os.replace(vor, ziel)


def lade(path, soll, hashcheck):
    data = open(path, "rb").read()
    ist = sha256(data)
    if hashcheck and (ist != soll["sha256"] or len(data) != soll["bytes"]):
        print("STOP %s ist %s/%s soll %s/%s" % (path, ist[:16], len(data), soll["sha16"], soll["bytes"]))
        raise SystemExit(2)
    return data.decode("utf-8")


def anwenden(root, fullcheck, hashcheck, dry, kein, minute):
    if not dry and not kein and sperre(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    pfad = {
        "dashboard.py": os.path.join(root, "dashboard.py"),
        "lage_pages.py": os.path.join(root, "lage_pages.py"),
        "flugfunk.py": os.path.join(root, "flugfunk.py"),
        "fullcheck.sh": fullcheck,
    }
    texte = {}
    fest = PAYLOAD["FEST_" + SCHLUESSEL]
    for name in PRUEFEN:
        texte[name] = lade(pfad[name], fest[name], hashcheck)
    for name, alt, neu, n in PAYLOAD[SCHLUESSEL]:
        texte[name] = ersetze(texte[name], alt, neu, name, n)
    for name in SCHREIBEN:
        if name.endswith(".py"):
            compile(texte[name], name, "exec")
    if "fullcheck.sh" in SCHREIBEN:
        tmp = fullcheck + ".haerten-tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(texte["fullcheck.sh"])
        probe = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
        if probe.returncode != 0:
            os.remove(tmp)
            print("STOP bash -n")
            return 2
        if dry:
            os.remove(tmp)
    if dry:
        print("dry-run: nichts geschrieben")
        for name in SCHREIBEN:
            data = texte[name].encode("utf-8")
            print("%s endstand sha16 %s bytes %s" % (name, sha256(data)[:16], len(data)))
        return 0
    kennung = "haerten-" + SCHLUESSEL.lower()
    for name in SCHREIBEN:
        sichere(pfad[name], kennung)
        tmp = pfad[name] + ".haerten-tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(texte[name])
        if name == "fullcheck.sh":
            probe = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
            if probe.returncode != 0:
                os.remove(tmp)
                print("STOP bash -n, fullcheck nicht ersetzt")
                return 2
        if os.path.exists(pfad[name]):
            shutil.copymode(pfad[name], tmp)
        os.replace(tmp, pfad[name])
        data = open(pfad[name], "rb").read()
        print("%s endstand sha256 %s bytes %s" % (name, sha256(data), len(data)))
    if not kein and not sperre(minute):
        for unit in DIENSTE:
            rc = subprocess.call(["systemctl", "restart", unit])
            print("restart %s rc %s" % (unit, rc))
    else:
        print("kein Neustart")
    return 0


def _basis_finden():
    for cand in (os.environ.get("HAERTEN_BASIS"), "/tmp/pi-stand", os.path.join(os.getcwd(), "pi-stand")):
        if cand and os.path.isfile(os.path.join(cand, "dashboard.py")) and os.path.isfile(os.path.join(cand, "flugfunk.py")):
            return cand
    raise SystemExit("STOP Selbsttest-Basis fehlt")


def _kopie(src):
    import tempfile
    ziel = tempfile.mkdtemp(prefix="haerten-")
    for name in ("dashboard.py", "lage_pages.py", "flugfunk.py", "fullcheck.sh"):
        shutil.copy2(os.path.join(src, name), os.path.join(ziel, name))
    return ziel


def _proxy_test(mod):
    import socket
    import threading
    import time
    from flask import Flask

    def dienen(bereit, art):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        bereit.append(srv.getsockname()[1])
        srv.settimeout(5)
        conn, _adr = srv.accept()
        puff = b""
        conn.settimeout(2)
        try:
            while b"\r\n\r\n" not in puff:
                puff += conn.recv(512)
        except OSError:
            pass
        if art == "ton":
            conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n" + b"\xff\xfb\x90\x00" * 40)
        elif art == "leer":
            conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n")
        else:
            conn.sendall(b"HTTP/1.0 404 Not Found\r\n\r\n")
        conn.close()
        srv.close()

    def fragen(art):
        bereit = []
        threading.Thread(target=dienen, args=(bereit, art), daemon=True).start()
        while not bereit:
            time.sleep(0.01)
        mod._ICECAST = ("127.0.0.1", bereit[0])
        app = Flask("flugfunk-proxy")
        app.add_url_rule("/flugfunk", view_func=lambda: mod.icecast_response("/tmp"))
        return app.test_client().get("/flugfunk")

    gut = fragen("ton")
    if gut.status_code != 200 or gut.mimetype != "audio/mpeg" or len(gut.data) < 16:
        raise SystemExit("selftest proxy ton %s %s" % (gut.status_code, len(gut.data)))
    for art in ("leer", "weg"):
        schlecht = fragen(art)
        if schlecht.status_code != 503 or schlecht.data[:3] == b"\xff\xfb":
            raise SystemExit("selftest proxy %s %s" % (art, schlecht.status_code))


def selftest():
    
    src = _basis_finden()
    roh = _kopie(src)
    fc = os.path.join(roh, "fullcheck.sh")
    vor = open(os.path.join(roh, "flugfunk.py"), "rb").read()
    rc = anwenden(roh, fc, True, True, True, 12)
    if rc != 0 or open(os.path.join(roh, "flugfunk.py"), "rb").read() != vor:
        raise SystemExit("selftest dry")
    rc = anwenden(roh, fc, True, False, False, 41)
    if rc != 2 or open(os.path.join(roh, "flugfunk.py"), "rb").read() != vor:
        raise SystemExit("selftest sperre")
    shutil.rmtree(roh)
    arbeit = _kopie(src)
    fc = os.path.join(arbeit, "fullcheck.sh")
    rc = anwenden(arbeit, fc, True, False, True, 12)
    if rc != 0:
        raise SystemExit("selftest lauf %s" % rc)
    text = open(os.path.join(arbeit, "flugfunk.py"), encoding="utf-8").read()
    lage = open(os.path.join(arbeit, "lage_pages.py"), encoding="utf-8").read()
    sh = open(fc, encoding="utf-8").read()
    if "_ICE_LOCK.acquire(blocking=False)" not in text or 'umgebung = {"PATH":' not in text or "log.close()" not in text:
        raise SystemExit("selftest flugfunk")
    if 'not lan_ok("")' not in text or "def _ice_loop" not in text:
        raise SystemExit("selftest lan")
    if lage.count("esc(it.text") != 2 or lage.count("esc(it.from") != 2:
        raise SystemExit("selftest esc")
    if "info() { :; }" in sh or "else :; fi" not in sh or 'FC_VERSION="2.10"' not in sh:
        raise SystemExit("selftest fullcheck")
    if "onstalled" not in text or "onemptied" not in text or "setTimeout(haengt, 5000)" not in text:
        raise SystemExit("selftest live-js")
    if "audio.src='/flugfunk?t='+Date.now();\n    audio.play();" in text:
        raise SystemExit("selftest ended")
    sys.path.insert(0, arbeit)
    import flugfunk
    flugfunk.selftest()
    gehalten = flugfunk._ICE_LOCK.acquire(blocking=False)
    if not gehalten:
        raise SystemExit("selftest lock frei")
    flugfunk.icecast_sicher(arbeit)
    flugfunk._ICE_LOCK.release()
    _proxy_test(flugfunk)

    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    parser.add_argument("--fullcheck", default="")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    fullcheck = args.fullcheck or "/home/fmg/fullcheck.sh"
    return anwenden(args.basis, fullcheck, True, args.dry_run, args.kein_neustart, berlin_minute())


if __name__ == "__main__":
    raise SystemExit(main())
