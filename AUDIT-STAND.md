# AUDIT-STAND – Prepper-Dashboard (BND-Prepper)

Stand: Samstag 31.10.2026, 00:22 Uhr (Berlin), aktualisiert fuer PERF-01: commit45a pipWaitress angewendet, commit45 perfWsgi veroeffentlicht (noch nicht angewendet). Keine Secrets in dieser Datei.
Geschrieben vom Ausfuehrungs-Agenten (Grok Bot) fuer Frank. Vorige Fassung: 30.10. 23:30 (Blob c50ab411).

Host: BND-Prepper, Debian 13 aarch64, systemd 257, Python 3.13, Port 5000, Benutzer fmg, Projekt `/home/fmg/prepper-dashboard`, kein node auf der Pi.
Audit-Dokument: `SECURITY_AND_PERFORMANCE_AUDIT.md` (41 Befunde: SEC-01..13, PERF-01..08, REL-01..10, MOD-01..10).

## 1. Ehrlicher Hinweis zur Genauigkeit

- Veroeffentlicht (Repos) und Angewendet (Pi) sind zwei Dinge. Die Hashes unten sind die **Soll-Werte aus den Patches**. Was auf der Pi wirklich liegt, muss dort gelesen werden:

      cd /home/fmg/prepper-dashboard && sha256sum *.py tools/*.sh | cut -c1-16,65-

  Nur die zwei Hauptdateien, ohne Pipe: `sha256sum /home/fmg/prepper-dashboard/dashboard.py /home/fmg/prepper-dashboard/lage_pages.py`

  (erste 16 Zeichen je Datei mit dem Soll vergleichen).
- Bestaetigt angewendet auf der Pi (Frank-Ausgaben): bis einschliesslich commit44 (dashboard.py `1898fde2aa91d066`, 21790 Zeilen, 1118288 B; lage_pages.py `7f9fc0cf17d52644`, 4480 Zeilen, 204586 B; 23 Marker je 1x). commit41 30.10. 19:42, commit42 30.10. 20:45, commit43 30.10. 22:08, commit44 30.10. 23:08, je alle Pruefungen OK.
- commit45a pipWaitress (PERF-01 Schritt A) angewendet (Rueckmeldung 31.10. 00:13): waitress 3.0.2 im venv bestaetigt (fmg:fmg; `~ip` im venv ist fmg:fmg). Kein Neustart, dashboard.py unveraendert.
- Davor: commit38 29.10. 22:33, commit39 29.10. 23:24, commit40 30.10. 06:36 (dashboard.py `f8977a31bf4c177f`, 26046 Zeilen).
- pegelFix (commit44) im Betrieb: Journal `pegelSplit aktiv: ... pegelFix: 3 Namen da`.
- Aeltere Bestaetigungen: commit34 25.10. 20:36, commit35 25.10. 20:42, commit36 26.10. ~18:23, commit37 26.10. ~19:05.
- relStop (commit39) im Betrieb bestaetigt: beim Neustart am 30.10. um 06:40:18 stand im Journal `relStop SIGTERM: uplinkDetect uplink_state.json gespeichert` und `fertig in 0.01 s`.
- Es gibt keine veroeffentlichten, aber nicht angewendeten Patches. Jeder Patch prueft die Basis per sha16 und stoppt sonst mit klarer Meldung.

## 2. Pi-Stand (sha16 = erste 16 Hex-Zeichen von sha256)

### dashboard.py – Kette (jeder Schritt = ein Patch, Basis-Check strikt)

| nach Patch | sha16 |
|---|---|
| Ausgang (vor commit30) | 565137da31dc675d |
| commit30 relWatch | 874452e6491a74c5 |
| commit31 dbVis | 3a933125227fb89b |
| commit31b mapUi | 9cb49ceab0243cc4 |
| commit32 modDead (MOD-08) | ee4ea3123eb561c4 |
| commit33 secXmlDash | 1574109c8609cf26 |
| commit34 wxSlot | 03ee294d6e4ed56f |
| commit35 clockOff | 1831e7cd923396d1 |
| commit36 ninaFix | 8510b08e868edc46 |
| commit37 hideTexts | bb94f52af6e03c3b |
| commit39 relStop (REL-10 Teil 3) | 7be7e011ee2426a6 |
| commit40 asyncMini | f8977a31bf4c177f (26046 Zeilen) |
| commit41 pagesSplit1 | 7ffa9d33c5fd4974 (25718 Zeilen) |
| commit42 pagesSplit2 | 6661a7f77b1e1487 (23683 Zeilen) |
| commit43 pagesSplit3 | 64a83af070677323 (21976 Zeilen) |
| commit44 pegelSplit | **1898fde2aa91d066** <- bestaetigter Pi-Stand (30.10. 23:08), 21790 Zeilen (Blob 891fd04f) |
| commit45 perfWsgi | d0f34851146d65b5 (21941 Zeilen, 1126150 B, Blob 223c51f4) <- Ziel, veroeffentlicht, auf der Pi noch nicht angewendet |

### lage_pages.py (neu seit commit41: Seitenvorlagen aus dashboard.py, nur Text)

| nach Patch | sha16 | Inhalt |
|---|---|---|
| commit41 pagesSplit1 | e7b3bb1ea1a145d3 (361 Zeilen) | PAGE_ADSB |
| commit42 pagesSplit2 | 6a596584014df095 (2471 Zeilen) | + PAGE4, PAGE_SPEICHER, PAGE_UMWELT2, PAGE_PI, PAGE_MESH, PAGE_NEWS, PAGE_LUFT |
| commit43 pagesSplit3 | 231d4c309c1ae009 (4241 Zeilen) | + PAGE1, PAGE2, PAGE3, PAGE_LOKALE_ENERGIE |
| commit44 pegelSplit | **7f9fc0cf17d52644** (4480 Zeilen) <- Pi-Stand, Branch-Blob 1f38c694 | + PAGE_PEGEL |

Marker in dashboard.py (je genau 1x): relHygiene, perfKeep, sameOrigin, alarmFaden, relWatch, dbVis, mapUi, modDead, secXmlDash, wxSlot, meshBootQuiet, funkHarden2, kartevec, clockOff, ninaFix, hideTexts, longArchive, relStop, asyncMini, pagesSplit1, pagesSplit2, pagesSplit3, pegelSplit (23); nach commit45 zusaetzlich perfWsgi (24).

### weitere Dateien (Soll laut Apply-Skripten; auf der Pi gegenpruefen, nicht alle in dieser Sitzung erneut gelesen)

| Datei | sha16 Soll | aus Patch |
|---|---|---|
| database.py | e7a7ef192c522480 | secXml (commit31x) |
| lage_xml.py | f77305fc17ed2f77 | secXml |
| mesh_bridge.py | 3482f6e386cf26ce | bridgeCore commit22 |
| mesh_bridge_bayern.py | c1176b457346ae49 | bridgeCore commit22 |
| mesh_bridge_core.py | ddc134f29a6a8949 | bridgeCore commit22 |
| luft.py | 0ccae0834ab27f6d | laut Apply-Skript, Patch nicht einzeln zugeordnet |
| secret_util.py | ff8e2ac7049f4bde | secHard commit24 |
| tools/backup.sh | 5053f6b8a43a8638 | relBackup2 commit18b |
| Restore-Werkzeug | c0e305b8ea4d9007 | relBackup commit18 |
| health_check.py | 5a0156ff02d5960c | relHygiene commit19b |
| prepper_docs.py | 41f34abc4cabeb5a | docsVer commit38 (29.10., bestaetigt; vorher 609f0a7f00ab586b) |
| prepper_sdr.py | 8b887c795e64b87f | laut PATCH_STANDARD Live-Stand (seit sdrStick3e unveraendert) |
| funk_health | f1b16a5f9bc7317c | relHygiene (aelterer Stand) |
| mesh_hang_watchdog | 1518dbd9931c5e96 | relHygiene (aelterer Stand) |
| lage_clock.py | sha256 beginnt c909aea1148518fe | relClock commit25 |
| lage_disk.py | sha256 beginnt 4b6b35ab7c97dfc7 | relClock; relClock2 (25b) kann abweichen |
| certs/sectigo-e36.pem | DER sha256 beginnt 873f0ba8 (Sectigo Public Server Authentication CA DV E36) | ninaFix commit36 |

Hinweis: Wo "aelterer Stand" steht, kann ein spaeterer Patch die Datei veraendert haben – dann zaehlt der Wert aus dem juengsten Apply-Skript. Im Zweifel `sha256sum` auf der Pi.

## 3. Veroeffentlichte Commits (Patches in prepper-patches/main, Repo Frankenland90/prepper-patches)

| Commit | Name | Audit-Bezug | Hash prepper-patches (main) |
|---|---|---|---|
| 16 | autogain | Gain-Wachter | 44e5c9cfd4e35980e8e4771c29b22499ea1c2b9e |
| 17 | sdrStick3e | SDR | 9bbc0faa842d3195ad5c89b8da22289556aa191f |
| 18 | relBackup | REL-03 (+PERF-03 Backup-Teil) | 9780e7eeb793f2503a73111a1874784e2a26b865 |
| 18b | relBackup2 | REL-03 | e8238f9e56fcdc1aaf19143a6e9a4d1878687a23 |
| 19 | relHygiene | REL-04, REL-09, SEC-13 Teil (Chart.js lokal) | 27b9fc2ff07cd1caea564ff17f081b6d1570252e |
| **19b** | relHygiene | s.o. (Korrektur) | d7cd5fc73f313d6abaa55e241e4da7cc4ae83b1a |
| 20 | bridgeDedup | MOD-02 | af0a063c4b2d02814075da67f2473ebdb04e26ed |
| 21 | bridgePrio | PERF-05 | a44729f2fde947fe64d22cd29eceb885f6dafc38 |
| **22** | bridgeCore | MOD-04 Stufe 1 | 7d109e3e40c6f19edc37931f00ad2c21e6eb3cea |
| 23 | relDb | REL-07, PERF-06 | f8d322e1162e40874ac07008cd3e44e8b2aa8ca7 |
| 24 | secHard | SEC-09/10/11 (Teil) | dbef0c647e7666f2fe2f313b7b1ac64b324d0424 |
| 25 | relClock | REL-05, REL-06 | 126b0d03c4f9717b08dd5c3114afcdc6cb11ac5e |
| 25b | relClock2 | REL-05/06 (Korrektur) | e4d682ac9280c41eb933f19b19fc88dc90537bb0 |
| 26 | secLoad | SEC-01 Code-Seite, SEC-04, SEC-12 | c45f1817cb5f0fe6cff1a1d3de696863e6994da4 |
| **27** | perfKeep | keep-last nur bei Aenderung, /pi-Ping aus Zwischenspeicher | b745ba6d0eda3e26fb8a15b9179ec1ec1bd792ff |
| **28** | sameOrigin | SEC-05, MOD-09 | c77631399378da94c085e4518346c82bdd673aa9 |
| **29** | alarmFaden | PERF-02 | 6e73f20dae435304ec86477acaac14df9989a09c (Fix: f0d7343026a1c8e67aa863d0756dbf565200d0e3) |
| **30** | relWatch | REL-01, REL-02 | b01bf99b77e0f6bd0e0b977221fe71cb95c1e25d (Stand-2-Fix: ebc3a4f1c0523e99cfd80d1c0b4c8d5b1569d0c2) |
| 31x | secXml | SEC-11 (XML/DB-Teil) | 2aa469eda8547094742992e0b4d273e537448a7f |
| **31** | dbVis | DB-Zeile in /pi | a92f793c9f48941b1bb0462f3258403d627086fd |
| **31b** | mapUi | Karten-UI | 67842589719335f802ee615d69445e858f54d236 |
| **32** | modDead | MOD-08 | dd7f3c09b8639295255c8ce9c520ebe4e37489a5 |
| **33** | secXmlDash | SEC-11 Dashboard-Seite | 35b8350161382c7cb17651af8c559caf55a37b9a |
| **34** | wxSlot | Wetter-Slot-Nachholung + Stromausfall-Zustand (Befund aus Pi-Journal) | cc913f0915af7e5784b9469095aa1c11e009fd1b |
| **35** | clockOff | Zeit-Offset-Kachel aus chrony statt ntplib-Artefakt | 6bcd6aed89a8bc38c6169dd03b04470c8c0387c9 |
| 36 | ninaFix | NINA-TLS: warnung.bund.de sendet kein Zwischenzertifikat; gepinnte Zwischenstelle Sectigo E36, kein verify=False | 5b9c1b48761bbc25995d090ae9dd34e85783dfb8 |
| 37 | hideTexts | Lage-Seite: Zertifikatsketten-Hinweis (NINA-Fallback) und SDR-Rollentext (bc_note) ausgeblendet; Fehler und Ablauf unter 90 Tagen bleiben sichtbar, Hinweis weiter im Journal und unter /api/nina-cert | 0c41ed06127a138da3a227b94b4480240fdcc5e1 |
| - | fullcheck.sh 2.0.1 | read-only Gesamtpruefung (Airspy per USB-Kennung, Stick-Namen nach Rolle, dmesg-Alter) | 7f6599346fb1394e71c0e4fe015b21825d770619 (2.0.0: b4bc2f19a61ba48060b349cc03e06ab7f00a0971) |
| **38** | docsVer | Docs-Version: prepper_docs.py Generator-Version 2 (Uhr-Kachel-Text, NINA-Texte neutral) | b682f2ac7dcbedfa986f316ea0e5288cbb85a4bc |
| **39** | relStop | REL-10 Teil 3: Zustaende beim Beenden sichern (SIGTERM-Haken vor longArchive, uplinkDetect force, Budget 4 s) | 32248b2dae03e58814c74a26c23a61320580a1ec |
| **40** | asyncMini | async-Minifix: verwaister `<script>async</script>` auf der Lage-Seite entfernt | dd70db25d6819156c2af032e901ba713766b5dd7 |
| **41** | pagesSplit1 | MOD-06/07 Pilot: ADS-B-Seitenvorlage nach lage_pages.py | b9f586a0820a02512e74272b6f95cf85f1dc6653 |
| **42** | pagesSplit2 | MOD-06/07: 7 Seitenvorlagen nach lage_pages.py | 9a1a5a215ba6a060fdfa24a64c4f3f2f79204c98 |
| **43** | pagesSplit3 | MOD-06/07: 4 Seitenvorlagen (Lage, Energie, System, Lokale Energie) | f6fe84cde9538b9ff8602fc9aabddf46009f6f53 |
| **44** | pegelSplit | pegelFix (NameError last_pegel_mesh_auto) + PAGE_PEGEL nach lage_pages.py | b7370c0d7208649c351d265e469a3976debc3ab5 |
| **45a** | pipWaitress | PERF-01 Schritt A: waitress 3.0.2 offline ins venv (eingebettetes Wheel, require-hashes) | 2b4f0d616f47f0875f2f521cf2255a4b191dd8d8 |
| **45** | perfWsgi | PERF-01 Schritt B: waitress statt Werkzeug-Entwicklungsserver (8 Faeden, ein Prozess) | 4c36ef9a80381c18a58be79f6b6c42804dd80652 |

Fett = vom Auftrag "19b/22/27–35" erfasst, sowie die neuen Commits 38–44.

### dashboard.py auf Branch `kaeswasser-lage-monitor` (Repo Frankenland90/kaeswasser-lage-monitor)

| Commit | Hash Branch |
|---|---|
| 30 relWatch | d9753790d012c51002f366dc27e73d0e9d5346ee |
| 31 | 0137a18590b11306cec16321b7a1f60e902868bb |
| 31b | 5c06731ede76f41fd2c0d73cd398af38034b23fe |
| 32 | 10226aac6c06b9b2c8f23ba85e18e385dd2a66c3 |
| 33 | 82a1be1a5ef5f565e3db0d2251fa8aede47680a5 |
| 34 | d4fea9c372b5dc2d3af500d4ee66df1d38d78557 |
| 35 | bd10e68dd1bb953ff74dceca6aba53a8de827d49 |
| 36 | 9b9cd7e41c2c67efdbfa335a723a00b01ec54827 |
| 37 | a9c4839496afe2a0e70eab1aa5e3f89bce1f6343 |
| 38 docsVer (prepper_docs.py, Blob 63befa06) | 7d2f4d68c2fd6ca1d899c452a6564cfe51d46e7c |
| 39 relStop (Blob 70e4d61d) | 39f667b66dfb6fe83b4580c469d6c980ef49677e |
| 40 asyncMini (Blob 1d08a37e) | 66e2026e355bd154c0a3e10b1faa04b275e35757 |
| 41 pagesSplit1 (dashboard.py + lage_pages.py neu) | e293475e8bc7089df71ecc9a77fee6f1589bdfde |
| 42 pagesSplit2 (Blobs a8f6c15f / 84269670) | d96af14ed3815fdab8479c803b096d0af9d9b794 |
| 43 pagesSplit3 (Blobs e821823c / 87a77cc9) | 9d874fa8aa3505e3f09df69fe4d0b88a60774fc4 |
| 44 pegelSplit (Blobs 891fd04f / 1f38c694) | bda993cbc77ee1f91e5a8ea26d47572b252f9d36 |
| 45 perfWsgi (dashboard.py Blob 223c51f4; lage_pages.py unveraendert) | a48c0483c93efde09b816c7090161b4659286b4a |

Aeltere Branch-Commits (secXml: lage_xml/database c7c27ed8…, requirements a2f411fa…, .gitignore 48a77020…, MOD-10-Aufraeumen archive/*, Audit-Doku eb48496f…): `git log` im Repo.

### Apply-Skripte (Groesse / sha256)

- apply-pagessplit1.sh (41): 47433 B, sha256 fff792932d760826005176faea15753928c26f14e304c7aae23e3de3155ac4c4
- apply-pagessplit2.sh (42): 53943 B, sha256 230b6d7a949fc4df56cfa09cdfab1365d606e74dc432655adcbdf9968b452aa0
- apply-pagessplit3.sh (43): 55022 B, sha256 89f18bc671afbe7121bef6134c5e0fdc9d9418bb0ad1b279fd1b64c5a931823b
- apply-pegelsplit.sh (44): 58782 B, sha256 d35ca97206613e336d7d9d30fcb012175c620a2631aa209b5c8ace45e8ad8d43
- apply-pipwaitress.sh (45a): 82984 B, sha256 d218e9b67652d9c53760673c8d2e2d5d40966c3b58d11207564f9a901d7641f3
- apply-perfwsgi.sh (45): 62882 B, sha256 60fd2672b0ffb0d4b9f1a8094616454e4a0c487caa1ac9ac7e4727f5fbf74860 (STOP, wenn waitress 3.0.2 nicht im venv ist)

- apply-docsver.sh (38): 50788 B, sha256 c1b0549ff7385040c9a8067c5500635f2a0733cbe0984158e2b2b347c567fd04
- apply-relstop.sh (39): 41179 B, sha256 1667ff4a6affee7f15f2ecd18814d2ee7f47ff944b03f832f3feadb2dcdad957
- apply-asyncmini.sh (40): 35404 B, sha256 2316fba9d9e471110ff80907e1adc5b2e783c5d1f3e1c6139026fc633a089add

Aufruf je Patch: `bash /tmp/apply-<name>.sh commitNN dry-run` (erst Trockenlauf), dann ohne `dry-run`. Ein sudo-Prompt, nur der Dienst prepper-dashboard wird neu gestartet. Ab commit39 gilt die Neustart-Sperre HH:55–HH:04 zu jeder Stunde (vorher nur um die Wetter-Slots 0,3,…,21 Uhr) – dann ab HH:05 neu starten.

## 4. Erledigte Audit-IDs (Patches veroeffentlicht)

REL-01, REL-02 (30), REL-03 (18/18b), REL-04, REL-09 (19/19b), REL-05, REL-06 (25/25b), REL-07 (23), MOD-02 (20), MOD-04 Stufe 1 (22), MOD-08 (32), MOD-09 (28), MOD-10 (Repo-Aufraeumen, Branch-Commits), PERF-02 (29), PERF-03 Backup-Teil (18), PERF-05 (21), PERF-06 (23), SEC-01 Code-Seite (26), SEC-04, SEC-12 (26), SEC-05 (28), SEC-09/10/11 (24, 31x, 33), SEC-13 Teil: Chart.js lokal (19). SEC-02/SEC-03 (Laufzeitdaten/.gitignore) laut Branch-Commits behandelt – in dieser Sitzung nicht neu geprueft.
REL-10 Teil 3 (39 relStop, im Betrieb bestaetigt). INT-3 (toter scanner_mode_set-Altcode mit sudo systemctl) erledigt durch commit32 modDead; am Stand f8977a31 gibt es kein `sudo systemctl` mehr im Dashboard.
PERF-01 (45a/45 veroeffentlicht; 45a angewendet, 45 steht aus): waitress 3.0.2, 8 Arbeitsfaeden, ein Prozess, Bind 0.0.0.0:5000, Unit unveraendert.
MOD-06/07 teilweise: 13 Seitenvorlagen in lage_pages.py (41-44), weitere Vorlagen und Code-Module offen. Befund NameError `last_pegel_mesh_auto` behoben (44 pegelFix; Sim-Nachweis: eine Pegel-Meldung pro Wetter-Slot wie vorher, keine zusaetzliche Sendung).
Zusatz ohne Audit-ID: commit27 perfKeep, 31 dbVis, 31b mapUi, 34 wxSlot (Wetter-Slot, aus Pi-Journal), 35 clockOff (Uhr-Kachel), 36 ninaFix (NINA-TLS), 37 hideTexts (Lage-Texte), 38 docsVer (Docs-Version), 40 asyncMini (async-Minifix), fullcheck.sh 2.0.1 (read-only Pruefskript).

## 5. Bewusst offen (Entscheidung Frank)

SEC-01 (nur Code-Seite erledigt, Rest bewusst offen), SEC-06, SEC-08.

## 6. Noch offen

- SEC-07; SEC-13 Rest
- PERF-03 (Rest), PERF-04, PERF-07, PERF-08
- REL-08
- REL-10 Teil 1 (Alarmfaeden und NINA/DWD-Sofortrunde vor dem ersten Voll-Update): braucht Freigabe von Frank. REL-10 Teil 2 (network-online.target nicht blockierend, Wait-Online-Zeitlimit): offen.
- MOD-01, MOD-03, MOD-05; MOD-06, MOD-07 (Seitenvorlagen in Schritten 41-44 begonnen, Rest offen)
- fullcheck.sh 2.0.1 meldet 84/100; ein Abzug ist ein Airspy-Fehlalarm, Korrektur als 2.0.2 geplant.
- Aufraeumen (offen, Auftrag vom 30.10. abgebrochen): ca. 250 alte `.bak`-Dateien im Projektordner in ein datiertes Archiv verschieben (nicht loeschen); ca. 130 tote Zeilen in prepper_sdr.py (3 ueberdeckte Erstfassungen: stk_run_cmds, stk_test_stick, _at_start)
- /pi-Antwortzeit: Median direkt nach dem Neustart wieder 2,2 s (commit44: vorher 0,20 s; ebenso bei commit36/37). Vermutlich Last des ersten Voll-Updates; Nachmessung im eingeschwungenen Zustand steht aus. Bleibt sie hoch, gehoert das zu PERF-01.
- PERF-01 (WSGI-Server), commit45 perfWsgi: Anwendung durch Frank steht aus (erst `dry-run`, Neustart-Sperre HH:55-HH:04). Aenderung: Block perfWsgi vor `__main__`, letzte Zeile im Hauptprogramm `app.run(...)` -> `_perf_serve()` (waitress `create_server` + `run` im Hauptfaden; kein `waitress.serve`, weil das `logging.basicConfig` setzt), toter `_dt_debug`-Haken ohne `@app.after_request`. Start weiter ueber `python dashboard.py` (alle Faeden wie bisher genau einmal; Sim: Fadenliste alt/neu gleich bis auf 8 x waitress), ohne waitress Rueckfall auf app.run wie bisher. Kein Zugriffsprotokoll, App-Fehler (500 + Traceback) ins Journal; waitress-Warnung `Task queue depth` hoechstens 1x/min als `perfWsgi: alle 8 Arbeitsfaeden belegt`. Neu: `/api/perfwsgi/status` (nur lesen). Unit unveraendert (NotifyAccess=main passt: Herzschlag aus dem Hauptprozess, Sim mit Absender-PID geprueft). Sim-Nachweise: Fadenzahl unter 48 parallelen Anfragen fest (Werkzeug: +8), relWatch-Haenger (alle 8 Arbeitsfaeden blockiert) -> WATCHDOG=trigger nach 196 s aus dem Hauptprozess, SIGTERM (auch im Haenger) -> relStop-Flush, Ende in 0,02 s, sysBoot-Zeitmessung (langsam > 3 s) wirkt. Restrisiko: mehr als 8 gleichzeitig lange Anfragen stauen sich; dauert das 180 s, startet relWatch neu.
- /pi-Antwortzeit nach perfWsgi im eingeschwungenen Zustand nachmessen (Grundlage fuer weitere PERF-Schritte).
- Befund am Rande: funk_health.py und funk_page.py machen `from dashboard import fetch_mesh_status`. Weil dashboard.py als Hauptprogramm laeuft, laedt das beim ersten Aufruf dashboard.py ein zweites Mal als Modul `dashboard`. Nicht geaendert, nur gemeldet.
- gepinnte Zwischenstelle certs/sectigo-e36.pem: noch ca. 3434 Tage gueltig (Stand 26.10.); entfaellt, sobald warnung.bund.de die Kette wieder vollstaendig sendet.
- `~ip` im venv (Rest eines abgebrochenen pip-Laufs): laut Frank 31.10. fmg:fmg, nicht mehr root; Entfernen gehoert zum Aufraeumen

## 7. Hinweise fuer den Wiedereinstieg

- Arbeitsordner auf der Box: `/workspace/<patchname>` (`wxslot`, `clockoff`, `bridges`, `relclock`, …) mit `mk/` (Edits, Block, Konfig, apply-*.sh), `src2/` (Pruefprogramm `guard_*.py`), `sim/` (Simulationen), `testout/`. Werkzeuge: `/workspace/lib/mk_apply_dash.py` (Apply-Generator), `/workspace/lib/run_sim_dash.sh`, `/workspace/lib/chain_dash.sh`. Fortschritt: `/workspace/rel01/PROGRESS.md`. Standard: `/workspace/audit-run/PATCH_STANDARD.md`.
- Naechster Patch baut nach Anwendung von commit45 auf dashboard.py `d0f34851146d65b5` und lage_pages.py `7f9fc0cf17d52644` auf (vorher `1898fde2aa91d066`); beide im Basis-Check. Marker-Pruefung: 24 Marker (mit perfWsgi). Werkzeuge perfWsgi: `/workspace/perfwsgi/` (mk/, sim/hw.sh fuer Faden-/Watchdog-/SIGTERM-Sim). Werkzeuge fuer weitere Seitenvorlagen: `/workspace/lib/pages/` (README.md; Namensliste reicht; Zusatzzeilen und spaetere `NAME = NAME.replace(...)`-Schichten werden unterstuetzt).
- Simulationen nur auf Port 5093, immer nur eine gleichzeitig, keine Screenshots.
- Kleine Fixes Docs-Version, REL-10 Teil 3, async-Minifix und INT-3 sind erledigt (30.10.).
- Modul-Aufteilung laeuft (commit41-44: 13 Seitenvorlagen, dashboard.py von 26046 auf 21790 Zeilen). Aufraeumen folgt spaeter. PERF-01: commit45 perfWsgi wartet auf Anwendung.
- **Freigabe von Frank noetig vor:** MOD-05, MOD-06, MOD-07, PERF-03 (Rest), PERF-04.
- Offene Beobachtung: fehlende Mesh-Meldungen werden vom anderen Worker untersucht (nicht Teil dieser Patches).

## 8. Dauerregeln

- Keine Schluessel/Keys, keine Provider-Aktionen (z. B. Accounts, Bestellungen, Tarife).
- Kein Eingriff in die Firewall.
- Keine Secrets in Repos, Dateien oder Berichten.
- Patch-Standard: strikter sha16-Basis-Check, Trockenlauf + idempotent, Backups `*.bak-<name>-JJJJMMTT-HHMMSS` (3 behalten), atomare Schreibvorgaenge, AST-Guard mit Mutationstest ohne node, py_compile mit System- und venv-Python, Sandbox-Selbsttests, nur betroffene Dienste neu starten, Smoke-Test aller 26 Seiten/APIs, Rollback mit klarer STOP-Meldung, ein sudo-Prompt, neue Docs-Version nur wenn prepper_docs.py im Umfang.
- Hoechstens 4 Dateien pro Push. Neustart-Sperre HH:55–HH:04.
- Sims nur auf Port 5093; Veroeffentlichung: prepper-patches (main) bekommt `apply-<name>.sh`, Branch kaeswasser-lage-monitor bekommt `dashboard.py` (und `lage_pages.py`); danach Raw-Pruefung (cmp, sha256, bash -n) gegen den festgenagelten Commit.
