#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-haerten-b. POST-Guard und Bind 192.168.178.99 plus 127.0.0.1. Setzt Patch A voraus."""
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

PAYLOAD = json.loads(r"""{"B": [["dashboard.py", "@app.route(\"/api/news_refresh\")\n", "@app.route(\"/api/news_refresh\", methods=[\"POST\"])\n", 1], ["dashboard.py", "@app.route(\"/api/download_test\")\n", "@app.route(\"/api/download_test\", methods=[\"POST\"])\n", 1], ["dashboard.py", "app.add_url_rule(\"/api/download_test\", endpoint=\"st_download_test\", view_func=_st_download_test, methods=[\"GET\"])\n", "app.add_url_rule(\"/api/download_test\", endpoint=\"st_download_test\", view_func=_st_download_test, methods=[\"POST\"])\n", 1], ["lage_pages.py", "    var r=await fetch(\"/api/download_test\");\n", "    var r=await fetch(\"/api/download_test\",{method:\"POST\",credentials:\"same-origin\",headers:{\"Content-Type\":\"application/json\"}});\n", 1], ["lage_pages.py", "    var r=await fetch(\"/api/news_refresh\");\n", "    var r=await fetch(\"/api/news_refresh\",{method:\"POST\",credentials:\"same-origin\",headers:{\"Content-Type\":\"application/json\"}});\n", 1], ["dashboard.py", "PW_HOST = \"0.0.0.0\"            # wie bisher app.run(host=\"0.0.0.0\")\n", "PW_HOST = \"192.168.178.99\"     # LAN plus 127.0.0.1. Fehlt die Adresse beim Start, Fallback 0.0.0.0 mit Journalzeile.\nPW_LISTEN = \"127.0.0.1:%d 192.168.178.99:%d\"\n", 1], ["dashboard.py", "    return {\"host\": PW_HOST, \"port\": int(port), \"threads\": PW_THREADS, \"ident\": \"waitress\", \"asyncore_use_poll\": True,\n            \"connection_limit\": 100, \"channel_timeout\": 120, \"expose_tracebacks\": False, \"clear_untrusted_proxy_headers\": True}\n", "    return {\"listen\": PW_LISTEN % (int(port), int(port)), \"threads\": PW_THREADS, \"ident\": \"waitress\", \"asyncore_use_poll\": True,\n            \"connection_limit\": 100, \"channel_timeout\": 120, \"expose_tracebacks\": False, \"clear_untrusted_proxy_headers\": True}\n", 1], ["dashboard.py", "    assert kw[\"host\"] == \"0.0.0.0\" and kw[\"port\"] == int(PORT), \"Bind\"\n", "    assert [x[3][0] for x in a.listen] == [\"127.0.0.1\", \"192.168.178.99\"], \"Bind\"\n", 1], ["dashboard.py", "        from waitress.server import create_server as _pw_create\n        srv = _pw_create(app, **_pw_kw(PORT))\n    except ImportError as e:\n        _PW[\"server\"], _PW[\"err\"] = \"werkzeug\", \"waitress fehlt: %s\" % e\n        print(\"perfWsgi FEHLER: waitress nicht ladbar (%s) - Start wie bisher mit Werkzeug (app.run)\" % e, flush=True)\n        app.run(host=\"0.0.0.0\", port=PORT, debug=False, use_reloader=False, threaded=True)\n        return\n    _PW[\"server\"], _PW[\"pid\"], _PW[\"t_listen\"] = \"waitress\", _pw_os.getpid(), _pw_time.time()\n    print(\"perfWsgi: waitress %s lauscht auf http://%s:%s (%d Arbeitsfaeden, ein Prozess, PID %d, kein Zugriffsprotokoll)\" % (_PW[\"version\"], PW_HOST, PORT, PW_THREADS, _pw_os.getpid()), flush=True)\n", "        from waitress.server import create_server as _pw_create\n    except ImportError as e:\n        _PW[\"server\"], _PW[\"err\"] = \"werkzeug\", \"waitress fehlt: %s\" % e\n        print(\"perfWsgi FEHLER: waitress nicht ladbar (%s) - Start wie bisher mit Werkzeug (app.run), Bind 0.0.0.0\" % e, flush=True)\n        app.run(host=\"0.0.0.0\", port=PORT, debug=False, use_reloader=False, threaded=True)\n        return\n    try:\n        srv = _pw_create(app, **_pw_kw(PORT))\n        gebunden = \"127.0.0.1 und 192.168.178.99\"\n    except OSError as _pw_bind:\n        print(\"perfWsgi: Bind 192.168.178.99 fehlgeschlagen (%s), Fallback 0.0.0.0\" % type(_pw_bind).__name__, flush=True)\n        srv = _pw_create(app, host=\"0.0.0.0\", port=int(PORT), threads=PW_THREADS, ident=\"waitress\", asyncore_use_poll=True, connection_limit=100, channel_timeout=120, expose_tracebacks=False, clear_untrusted_proxy_headers=True)\n        gebunden = \"0.0.0.0\"\n    _PW[\"server\"], _PW[\"pid\"], _PW[\"t_listen\"] = \"waitress\", _pw_os.getpid(), _pw_time.time()\n    print(\"perfWsgi: waitress %s lauscht auf %s Port %s (%d Arbeitsfaeden, ein Prozess, PID %d, kein Zugriffsprotokoll)\" % (_PW[\"version\"], gebunden, PORT, PW_THREADS, _pw_os.getpid()), flush=True)\n", 1], ["dashboard.py", "    print(f\"Käswasser Lage Monitor auf http://0.0.0.0:{PORT}\")\n", "    print(f\"Käswasser Lage Monitor auf http://192.168.178.99:{PORT} und http://127.0.0.1:{PORT}\")\n", 1]], "FEST_B": {"dashboard.py": {"sha256": "bd5efb5b00eb43b43ac7ef5f0a53548cfcd3cc34c8dc055525489769fe363df9", "sha16": "bd5efb5b00eb43b4", "bytes": 1391222}, "lage_pages.py": {"sha256": "bf675e1494a10891f0febad2db6fa77f9e5f8588ec718bf6893f5861d37e3f5b", "sha16": "bf675e1494a10891", "bytes": 231326}, "flugfunk.py": {"sha256": "c45120614a9970db11412965fcbca7683d6d206e47dbf32f51e887440c7cc9ed", "sha16": "c45120614a9970db", "bytes": 99369}, "fullcheck.sh": {"sha256": "0ae1da413408a99b438d488691b5902e792e57fe62fcfc11f8d60abe4cfdcfc3", "sha16": "0ae1da413408a99b", "bytes": 99209}}}""")
SCHLUESSEL = "B"
SCHREIBEN = ["dashboard.py", "lage_pages.py"]
PRUEFEN = ["dashboard.py", "lage_pages.py", "flugfunk.py", "fullcheck.sh"]
DIENSTE = ["prepper-dashboard"]
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



def _flask_seiten(dash):
    import ast
    import re
    from flask import Flask
    baum = ast.parse(dash)
    namen = ("_so_origin_ok", "_so_loopback", "_so_allowed", "_so_guard")
    teile = []
    for knoten in baum.body:
        if isinstance(knoten, ast.FunctionDef) and knoten.name in namen:
            teile.append(ast.get_source_segment(dash, knoten))
    if len(teile) != 4:
        raise SystemExit("selftest guard %s" % len(teile))
    ns = {"_SO_STAT": {"denied": 0, "last_log": {}, "quiet": True}, "_SO_LOG_GAP": 30.0}
    exec("\n\n".join(teile), ns)
    app = Flask("haerten")
    app.before_request(ns["_so_guard"])
    seiten = []
    gesehen = set()
    for pfad, methods in re.findall(r'@app\.route\("([^"<]+)"(?:, methods=\[([^\]]*)\])?\)', dash):
        if pfad in gesehen or (methods and "GET" not in methods and "POST" in methods):
            continue
        if pfad in ("/api/download_test", "/api/news_refresh"):
            continue
        gesehen.add(pfad)
        seiten.append(pfad)
        app.add_url_rule(pfad, endpoint="p" + str(len(seiten)), view_func=lambda: ("ok", 200))
    app.add_url_rule("/api/download_test", endpoint="dl", view_func=lambda: ("messung", 200), methods=["POST"])
    app.add_url_rule("/api/news_refresh", endpoint="nr", view_func=lambda: ("news", 200), methods=["POST"])
    c = app.test_client()
    for pfad in seiten:
        antwort = c.get(pfad)
        if antwort.status_code != 200:
            raise SystemExit("selftest seite %s %s" % (pfad, antwort.status_code))
    for pfad in ("/api/download_test", "/api/news_refresh"):
        if c.get(pfad).status_code != 405:
            raise SystemExit("selftest get %s" % pfad)
        if c.post(pfad, headers={"Origin": "http://evil.example"}).status_code != 403:
            raise SystemExit("selftest herkunft %s" % pfad)
        gut = c.post(pfad, headers={"Origin": "http://localhost", "Content-Type": "application/json"}, data="{}")
        if gut.status_code != 200:
            raise SystemExit("selftest post %s %s" % (pfad, gut.status_code))
    if not seiten:
        raise SystemExit("selftest keine seiten")

def selftest():
    
    src = _basis_finden()
    arbeit = _kopie(src)
    fc = os.path.join(arbeit, "fullcheck.sh")
    import importlib.util
    a_pfad = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apply-haerten-a.py")
    spec = importlib.util.spec_from_file_location("haerten_a", a_pfad)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if mod.anwenden(arbeit, fc, True, False, True, 12) != 0:
        raise SystemExit("selftest A")
    vor_b = open(os.path.join(arbeit, "dashboard.py"), "rb").read()
    if anwenden(arbeit, fc, True, True, True, 12) != 0 or open(os.path.join(arbeit, "dashboard.py"), "rb").read() != vor_b:
        raise SystemExit("selftest dry B")
    if anwenden(arbeit, fc, True, False, False, 2) != 2:
        raise SystemExit("selftest sperre B")
    if anwenden(arbeit, fc, True, False, True, 15) != 0:
        raise SystemExit("selftest lauf B")
    dash = open(os.path.join(arbeit, "dashboard.py"), encoding="utf-8").read()
    lage = open(os.path.join(arbeit, "lage_pages.py"), encoding="utf-8").read()
    if '@app.route("/api/download_test", methods=["POST"])' not in dash or '@app.route("/api/news_refresh", methods=["POST"])' not in dash:
        raise SystemExit("selftest routen")
    if "PW_LISTEN" not in dash or "Fallback 0.0.0.0" not in dash:
        raise SystemExit("selftest bind")
    if 'fetch("/api/download_test",{method:"POST"' not in lage or 'fetch("/api/news_refresh",{method:"POST"' not in lage:
        raise SystemExit("selftest fetch")
    _flask_seiten(dash)

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
