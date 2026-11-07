#!/usr/bin/env python3
# Kompakter Apply: nur die zwei EG-Texte "Selbsttest: kein Test"
# -> "Selbsttest: Auswertung nicht eingerichtet" in lage_pages.py.
# HTML id=usvEgTest und der JS-Fallback. Der test_txt-Zweig bleibt.
# Kein Netz, kein Dienstneustart, keine weitere Datei, keine Komplettnutzlast.

from __future__ import annotations

import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

ZIEL = Path("/home/fmg/prepper-dashboard/lage_pages.py")

HTML_ALT = '    <div class="small" id="usvEgTest">Selbsttest: kein Test</div>'
HTML_NEU = '    <div class="small" id="usvEgTest">Selbsttest: Auswertung nicht eingerichtet</div>'
JS_ALT = (
    "    tx('usvEgTest',u.test_txt?('Selbsttest: kein eigener Test · Geräteangabe '"
    "+String(u.test_txt).slice(0,60)):'Selbsttest: kein Test');"
)
JS_NEU = (
    "    tx('usvEgTest',u.test_txt?('Selbsttest: kein eigener Test · Geräteangabe '"
    "+String(u.test_txt).slice(0,60)):'Selbsttest: Auswertung nicht eingerichtet');"
)
ZWEIG = "Selbsttest: kein eigener Test · Geräteangabe"
ALT = "Selbsttest: kein Test"
NEU = "Selbsttest: Auswertung nicht eingerichtet"


def enc(text: str) -> bytes:
    return text.encode("utf-8")


def syntax(data: bytes, name: str) -> str | None:
    try:
        compile(data, name, "exec")
    except SyntaxError as exc:
        return "Zeile %s: %s" % (exc.lineno, exc.msg)
    return None


def neustart_gesperrt(minute: int) -> bool:
    """Sperre HH:50-HH:04 plus 5 min Vorlauf: Minute 45-59 und 00-04."""
    if minute < 0 or minute > 59:
        raise ValueError(minute)
    return minute >= 45 or minute <= 4


def lage(data: bytes) -> tuple[str, str]:
    ho, hn = data.count(enc(HTML_ALT)), data.count(enc(HTML_NEU))
    jo, jn = data.count(enc(JS_ALT)), data.count(enc(JS_NEU))
    po, pn = data.count(enc(ALT)), data.count(enc(NEU))
    br = data.count(enc(ZWEIG))
    if br != 1:
        return "halt", "unbekannt: test_txt-Zweig nicht genau einmal (%d)" % br
    if ho == 1 and hn == 0 and jo == 1 and jn == 0 and po == 2 and pn == 0:
        return "alt", "beide EG-Stellen alt"
    if ho == 0 and hn == 1 and jo == 0 and jn == 1 and po == 0 and pn == 2:
        return "neu", "beide EG-Stellen neu"
    if (ho + hn) and (jo + jn) and (ho, hn) != (jo, jn):
        return "halt", "gemischt: HTML alt/neu %d/%d, JS alt/neu %d/%d" % (ho, hn, jo, jn)
    if ho > 1 or hn > 1 or jo > 1 or jn > 1 or (ho and hn) or (jo and jn):
        return "halt", "gemischt oder mehrfach: HTML %d/%d JS %d/%d" % (ho, hn, jo, jn)
    return "halt", (
        "unbekannt: HTML alt/neu %d/%d, JS alt/neu %d/%d, Phrase alt/neu %d/%d"
        % (ho, hn, jo, jn, po, pn)
    )


def ohne(data: bytes, neu: bool) -> bytes:
    html = enc(HTML_NEU if neu else HTML_ALT)
    js = enc(JS_NEU if neu else JS_ALT)
    if data.count(html) != 1 or data.count(js) != 1:
        raise RuntimeError("Kontext nicht genau einmal")
    return data.replace(html, b"", 1).replace(js, b"", 1)


def tausch(data: bytes, rueck: bool) -> bytes:
    paare = ((HTML_NEU, HTML_ALT), (JS_NEU, JS_ALT)) if rueck else ((HTML_ALT, HTML_NEU), (JS_ALT, JS_NEU))
    out = data
    for alt, neu in paare:
        quelle, ziel = enc(alt), enc(neu)
        if out.count(quelle) != 1:
            raise RuntimeError("Stelle nicht genau einmal")
        out = out.replace(quelle, ziel, 1)
    return out


def sichern(path: Path, data: bytes, art: str) -> Path:
    stempel = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
    bak = path.with_name(path.name + ".bak-usv-eg-selbsttest-" + art + "-" + stempel)
    if bak.exists():
        raise RuntimeError("Sicherung existiert schon: %s" % bak)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung weicht ab")
    return bak


def schreiben(path: Path, neu: bytes) -> None:
    mode = path.stat().st_mode & 0o777
    tmp = path.with_name("." + path.name + ".tmp-usv-eg-selbsttest")
    if tmp.exists():
        raise RuntimeError("temporaere Datei existiert schon: %s" % tmp)
    try:
        with open(tmp, "wb") as handle:
            handle.write(neu)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        gelesen = tmp.read_bytes()
        if gelesen != neu:
            raise RuntimeError("temporaere Datei weicht ab")
        fehler = syntax(gelesen, str(path))
        if fehler:
            raise RuntimeError("Syntax der neuen Datei: %s" % fehler)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
    if path.read_bytes() != neu:
        raise RuntimeError("Datei nach Austausch weicht ab")
    ordner = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(ordner)
    finally:
        os.close(ordner)


def fenster() -> int:
    try:
        from zoneinfo import ZoneInfo
        jetzt = datetime.now(ZoneInfo("Europe/Berlin"))
    except Exception as exc:
        print("Zeitzone Europe/Berlin nicht verfuegbar (%s). Kein Neustart." % exc)
        return 2
    minute = jetzt.minute
    print("Berlin %s Minute %02d" % (jetzt.strftime("%Y-%m-%d %H:%M"), minute))
    if neustart_gesperrt(minute):
        print("Fenster gesperrt (Minute %02d). Kein Neustart." % minute)
        print("Sperre HH:50-HH:04 plus 5 min Vorlauf: Minute 45-59 und 00-04.")
        return 2
    print("Fenster frei (Minute 05-44). Gesperrt bleibt 45-59 und 00-04.")
    print("Dieses Skript startet keinen Dienst. Neustart nur getrennt von Hand:")
    print("sudo systemctl restart prepper-dashboard")
    return 0


def pruefen(data: bytes) -> int:
    stand, meldung = lage(data)
    print(meldung)
    print("bytes %d" % len(data))
    print("phrase_alt %d" % data.count(enc(ALT)))
    print("phrase_neu %d" % data.count(enc(NEU)))
    print("test_txt_zweig %d" % data.count(enc(ZWEIG)))
    return 0 if stand in ("alt", "neu") else 2


def anwenden(path: Path, dry: bool, rueck: bool) -> int:
    if path.is_symlink() or not path.is_file():
        print("Abbruch: Zieldatei fehlt oder ist ein Symlink: %s" % path)
        print("Kein Schreiben.")
        return 2
    data = path.read_bytes()
    stand, meldung = lage(data)
    print(meldung)
    if stand == "halt":
        print("Kein Schreiben.")
        return 2
    zielstand = "alt" if rueck else "neu"
    if stand == zielstand:
        print("bereits im Zielstand, keine Aenderung")
        print("Kein Schreiben, kein Neustart.")
        return 0
    try:
        neu = tausch(data, rueck)
        rest_alt = ohne(data, stand == "neu")
        rest_neu = ohne(neu, zielstand == "neu")
    except RuntimeError as exc:
        print("Abbruch vor Schreiben: %s" % exc)
        print("Kein Schreiben.")
        return 2
    if rest_alt != rest_neu or neu == data:
        print("Abbruch vor Schreiben: uebrige Bytes wuerden sich aendern")
        print("Kein Schreiben.")
        return 2
    if neu.count(enc(ZWEIG)) != 1:
        print("Abbruch vor Schreiben: test_txt-Zweig veraendert")
        print("Kein Schreiben.")
        return 2
    stand2, meldung2 = lage(neu)
    if stand2 != zielstand:
        print("Abbruch vor Schreiben: Ergebnis %s" % meldung2)
        print("Kein Schreiben.")
        return 2
    fehler = syntax(data, str(path))
    if fehler:
        print("Abbruch vor Schreiben: bestehende Datei syntaktisch ungueltig: %s" % fehler)
        print("Kein Schreiben.")
        return 3
    fehler = syntax(neu, str(path))
    if fehler:
        print("Abbruch vor Schreiben: Ergebnis syntaktisch ungueltig: %s" % fehler)
        print("Kein Schreiben.")
        return 3
    print("nur EG-HTML und EG-Fallback, %d Bytes -> %d Bytes" % (len(data), len(neu)))
    print("test_txt-Zweig bleibt, uebrige Bytes bleiben")
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        return 0
    try:
        bak = sichern(path, data, "rollback" if rueck else "apply")
        schreiben(path, neu)
    except (OSError, RuntimeError) as exc:
        print("Abbruch: %s" % exc)
        print("Zieldatei unveraendert, falls der Austausch nicht gemeldet wurde.")
        return 3
    print("geschrieben, Sicherung %s" % bak)
    print("Ruecknahme nur der zwei Stellen: python3 %s --rollback" % Path(sys.argv[0]).name)
    print("Das setzt nur diese zwei EG-Texte zurueck. Alle anderen Bytes bleiben.")
    print("Die Sicherung ist die ganze Datei vor dem Schreiben.")
    print("Kein Neustart.")
    return 0


def _fixture(html: str = HTML_ALT, js: str = JS_ALT, extra: bytes = b"") -> bytes:
    return (
        b"text = '''\n"
        + enc(html)
        + b"\n"
        + enc(js)
        + b"\n'''\n# FREMD-DSL-GAS-MARKER\n# SPITZ Selbsttest: noch keiner erkannt\nwert = 1\n"
        + extra
    )


def _lauf(argv: list[str]) -> int:
    try:
        return main(argv)
    except SystemExit as exc:
        code = exc.code
        if code in (None, 0):
            return 0
        if isinstance(code, int):
            return code
        print(code)
        return 1


def selftest() -> int:
    import io
    import tempfile
    from contextlib import redirect_stdout

    def still(argv: list[str]) -> tuple[int, str]:
        puffer = io.StringIO()
        with redirect_stdout(puffer):
            code = _lauf(argv)
        return code, puffer.getvalue()

    with tempfile.TemporaryDirectory() as tmp:
        wurzel = Path(tmp)
        ziel = wurzel / "lage_pages.py"
        fremd = b"# FREMD-DSL-GAS-MARKER\n"
        spitz = b"# SPITZ Selbsttest: noch keiner erkannt\n"

        ziel.write_bytes(_fixture())
        vorher = ziel.read_bytes()
        code, text = still(["apply", "--datei", str(ziel), "--dry-run"])
        assert code == 0 and "DRY-RUN" in text, text
        assert ziel.read_bytes() == vorher
        assert list(wurzel.glob("*.bak-usv-eg-selbsttest-*")) == []

        code, text = still(["apply", "--datei", str(ziel)])
        assert code == 0 and "geschrieben" in text, text
        nachher = ziel.read_bytes()
        assert ohne(vorher, False) == ohne(nachher, True)
        assert fremd in nachher and spitz in nachher
        assert syntax(nachher, "fixture") is None
        assert lage(nachher)[0] == "neu"
        backups = list(wurzel.glob("*.bak-usv-eg-selbsttest-*"))
        assert len(backups) == 1 and backups[0].read_bytes() == vorher

        code, text = still(["apply", "--datei", str(ziel)])
        assert code == 0 and "keine Aenderung" in text, text
        assert ziel.read_bytes() == nachher
        assert list(wurzel.glob("*.bak-usv-eg-selbsttest-*")) == backups
        assert not list(wurzel.glob(".lage_pages.py.tmp-usv-eg-selbsttest"))
        code, text = still(["apply", "--datei", str(ziel), "--pruefen"])
        assert code == 0 and "beide EG-Stellen neu" in text and "phrase_neu 2" in text, text
        assert "phrase_alt 0" in text and "test_txt_zweig 1" in text
        assert ziel.read_bytes() == nachher

        ziel.write_bytes(nachher + b"# DANACH-FREMD\n")
        mit_danach = ziel.read_bytes()
        code, text = still(["apply", "--datei", str(ziel), "--rollback"])
        assert code == 0 and "geschrieben" in text, text
        zurueck = ziel.read_bytes()
        assert b"# DANACH-FREMD\n" in zurueck and fremd in zurueck and spitz in zurueck
        assert lage(zurueck)[0] == "alt"
        assert ohne(mit_danach, True) == ohne(zurueck, False)
        code, _text = still(["apply", "--datei", str(ziel), "--rollback"])
        assert code == 0 and ziel.read_bytes() == zurueck

        ziel.write_bytes(_fixture(html=HTML_NEU, js=JS_ALT))
        gemischt = ziel.read_bytes()
        code, text = still(["apply", "--datei", str(ziel)])
        assert code == 2 and "gemischt" in text and "Kein Schreiben" in text, text
        assert ziel.read_bytes() == gemischt

        ziel.write_bytes(_fixture(extra=b'hinweis = "Selbsttest: kein Test"\n'))
        unbekannt = ziel.read_bytes()
        code, text = still(["apply", "--datei", str(ziel), "--dry-run"])
        assert code == 2 and "unbekannt" in text and "Kein Schreiben" in text, text
        assert ziel.read_bytes() == unbekannt

        ziel.write_bytes(_fixture() + b"def (\n")
        kaputt = ziel.read_bytes()
        code, text = still(["apply", "--datei", str(ziel)])
        assert code == 3 and "syntaktisch" in text and "Kein Schreiben" in text, text
        assert ziel.read_bytes() == kaputt

        code, text = still(["apply", "--datei", str(wurzel / "fehlt.py"), "--dry-run"])
        assert code == 2 and "Kein Schreiben" in text, text

        repo = Path(__file__).resolve().parent.parent / "lage_pages.py"
        if repo.is_file() and repo.resolve() != ZIEL.resolve():
            roh = repo.read_bytes()
            assert syntax(roh, str(repo)) is None
            assert lage(roh)[0] == "neu", lage(roh)
            alt = tausch(roh, True)
            assert b"Selbsttest: noch keiner erkannt" in alt
            fremd_repo = alt.replace(
                b"Selbsttest: noch keiner erkannt",
                b"Selbsttest: noch keiner erkannt FREMD",
                1,
            ) + b"\n# FREMD-AENDERUNG-AUSSERHALB\n"
            kopie = wurzel / "repo_lage_pages.py"
            kopie.write_bytes(fremd_repo)
            code, text = still(["apply", "--datei", str(kopie), "--dry-run"])
            assert code == 0 and kopie.read_bytes() == fremd_repo, text
            code, text = still(["apply", "--datei", str(kopie)])
            assert code == 0, text
            angewendet = kopie.read_bytes()
            assert ohne(fremd_repo, False) == ohne(angewendet, True)
            assert b"Selbsttest: noch keiner erkannt FREMD" in angewendet
            assert b"# FREMD-AENDERUNG-AUSSERHALB\n" in angewendet
            assert lage(angewendet)[0] == "neu"
            assert syntax(angewendet, "repo") is None
            print("repo-kopie fremdaenderung erhalten")

    assert neustart_gesperrt(45) and neustart_gesperrt(50) and neustart_gesperrt(59)
    assert neustart_gesperrt(0) and neustart_gesperrt(4)
    assert not neustart_gesperrt(5) and not neustart_gesperrt(41) and not neustart_gesperrt(44)
    code, text = still(["apply", "--fenster"])
    assert code in (0, 2), text
    if code == 0:
        assert "Fenster frei" in text and "sudo systemctl restart prepper-dashboard" in text
    else:
        assert "gesperrt" in text and "sudo" not in text
    rumpf = Path(__file__).read_text(encoding="utf-8").split("def selftest", 1)[0]
    for verboten in ("os.system", "subprocess", "urllib", "socket", "requests"):
        assert verboten not in rumpf, verboten
    print("selftest ok")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    dry = rueck = nur_fenster = nur_selftest = nur_pruefen = False
    datei: Path | None = None
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--dry-run":
            dry = True
        elif arg == "--rollback":
            rueck = True
        elif arg == "--fenster":
            nur_fenster = True
        elif arg == "--selftest":
            nur_selftest = True
        elif arg == "--pruefen":
            nur_pruefen = True
        elif arg == "--datei":
            index += 1
            if index >= len(args):
                print("Abbruch: --datei braucht einen Pfad")
                return 2
            datei = Path(args[index])
        else:
            print("Abbruch: unbekanntes Argument %s" % arg)
            return 2
        index += 1
    if nur_selftest:
        if args != ["--selftest"]:
            print("Abbruch: --selftest steht allein")
            return 2
        return selftest()
    if nur_fenster:
        if args != ["--fenster"]:
            print("Abbruch: --fenster steht allein")
            return 2
        return fenster()
    if datei is None:
        datei = ZIEL
    if nur_pruefen:
        if dry or rueck:
            print("Abbruch: --pruefen steht ohne --dry-run und ohne --rollback")
            return 2
        if datei.is_symlink() or not datei.is_file():
            print("Abbruch: Zieldatei fehlt oder ist ein Symlink: %s" % datei)
            return 2
        return pruefen(datei.read_bytes())
    return anwenden(datei, dry, rueck)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
