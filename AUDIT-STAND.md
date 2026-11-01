# AUDIT-STAND – Prepper-Dashboard (BND-Prepper)

Stand: Sonntag 01.11.2026, 08:45 Uhr (Berlin), aktualisiert: commit48 bis commit59 nachgetragen (commit57/58 am 01.11. angewendet, commit59 veroeffentlicht und wird gerade eingespielt). Keine Secrets und keine Seriennummern in dieser Datei.
Geschrieben vom Ausfuehrungs-Agenten (Grok Bot) fuer Frank. Vorige Fassung: 31.10. 12:57 (Stand nach commit47).

Host: BND-Prepper, Debian 13 aarch64, systemd 257, Python 3.13, Port 5000, Benutzer fmg, Projekt `/home/fmg/prepper-dashboard`, kein node auf der Pi.
Audit-Dokument: `SECURITY_AND_PERFORMANCE_AUDIT.md` (41 Befunde: SEC-01..13, PERF-01..08, REL-01..10, MOD-01..10).

## 1. Ehrlicher Hinweis zur Genauigkeit

- Veroeffentlicht (Repos) und Angewendet (Pi) sind zwei Dinge. Die Hashes unten sind die **Soll-Werte aus den Patches**. Was auf der Pi wirklich liegt, muss dort gelesen werden:

      cd /home/fmg/prepper-dashboard && sha256sum *.py tools/*.sh | cut -c1-16,65-

  Nur die zwei Hauptdateien, ohne Pipe: `sha256sum /home/fmg/prepper-dashboard/dashboard.py /home/fmg/prepper-dashboard/lage_pages.py`

  (erste 16 Zeichen je Datei mit dem Soll vergleichen).
- commit57 usvShutdown und commit58 dokuStand am 01.11. 06:26-06:30 angewendet, alle Pruefungen OK (Frank-Ausgabe): dashboard.py `7d494c1a21e50e96` (25247 Zeilen, 36 Marker je 1x), lage_pages.py `a9740c629a41806c` (4547 Zeilen), ups_manager.py `ef0b9e3d4bf42003`, prepper_sdr.py `264ef34996e17753`, prepper_evlog.py `8bffd396972b60fa`, prepper_docs.py `43032d218135e329` (Generator 3, Beschreibung v20261101-0630). upsmon aktiv, Status OL, kein killpower-Merker. Smoke 13 Seiten + 14/15 APIs 200.
- commit48 bis commit56 waren davor angewendet (der Basis-Check von commit57 fand am 01.11. dashboard.py `35fbc0604b09c0dd` = Ziel commit56, lage_pages.py `92a37e6326f0900d`, NUT wie nach commit55).
- commit59 snFrei: erster Bau (main 37eb40ad, sha256 162b63d0...) stoppte am 01.11. auf der Pi ohne Aenderung im Selbsttest selftest_sdrstick3e. Ursache: der Test las die echte Pi-Last (os.getloadavg, Schwelle 0,8 je Kern) - beim Einspielen lag sie darueber; der unveraenderte commit58-Stand scheitert unter Last genauso. Zusaetzlich scheiterten Selbsttests in den Stunden 03 und 05 (Kalibrierstunden). Korrigierter Bau main d1e54d4e (sha256 f70d332f...) wird gerade eingespielt - Ergebnis noch nicht bestaetigt.
- commit47 angewendet 31.10. 11:30, alle Pruefungen OK: dashboard.py `74ac7bfd0eebd4e0` (22340 Zeilen, 26 Marker je 1x), lage_pages.py `1d33ae9fd78f53dc` (4496 Zeilen), prepper_sdr.py `0900bfe6ba67e657` (14126 Zeilen), fullcheck.sh 2.0.2 (`192f3b9b1c0f6418`). Smoke 26/26, nur prepper-dashboard neu gestartet (prepper-sdr nicht). /pi-Median 0,238 s direkt nach dem Neustart (vorher 0,200 s). Sicherungen `*.bak-commit47-20261031-112144`, Archiv `bak-archiv/20261031-112144` (4 Dateien, 3,2 MB, dazu der `~ip`-Rest).
- fullcheck 2.0.2 danach: 98/100, 121 OK, 1 HINWEIS (Stick 2 hobby laut fullcheck nicht am USB-Bus - laut Frank NICHT abgezogen, Hinweis wird untersucht), 0 FEHLER; der Airspy-Fehlalarm aus 2.0.1 ist weg.
- commit46 perf03Cache angewendet 31.10. 07:31, alle Pruefungen OK, 25 Marker. Messung danach: /api/frequenz 0,009 s, /pegel 0,052 s (vorher 0,088 s / 0,489 s). Stand danach: dashboard.py `4594deab53d8ce7b` (22185 Zeilen), lage_pages.py `7f9fc0cf17d52644`, prepper_sdr.py `8b887c795e64b87f`, fullcheck.sh 2.0.1.
- Davor bestaetigt (Frank-Ausgaben): bis einschliesslich commit45 (dashboard.py `d0f34851146d65b5`, 21941 Zeilen, 1126150 B; lage_pages.py `7f9fc0cf17d52644`, 4480 Zeilen, 204586 B; 24 Marker je 1x).
- commit45 perfWsgi (PERF-01 Schritt B) angewendet 31.10. 05:42, alle Pruefungen OK. Backup `dashboard.py.bak-perfwsgi-20261031-053828`. Laufzeit: waitress 3.0.2, 8 Arbeitsfaeden, PID 46322, Faeden gesamt 27, unter 48 parallelen Anfragen fest. /pi-Median 0,196 s direkt nach dem Neustart, eingeschwungen 0,183-0,190 s (vorher unter Werkzeug 0,177 s).
- Davor bis commit44 (dashboard.py `1898fde2aa91d066`, 21790 Zeilen, 1118288 B; 23 Marker): commit41 30.10. 19:42, commit42 30.10. 20:45, commit43 30.10. 22:08, commit44 30.10. 23:08, je alle Pruefungen OK.
- commit45a pipWaitress (PERF-01 Schritt A) angewendet (Rueckmeldung 31.10. 00:13): waitress 3.0.2 im venv bestaetigt (fmg:fmg; `~ip` im venv ist fmg:fmg). Kein Neustart, dashboard.py unveraendert.
- Davor: commit38 29.10. 22:33, commit39 29.10. 23:24, commit40 30.10. 06:36 (dashboard.py `f8977a31bf4c177f`, 26046 Zeilen).
- pegelFix (commit44) im Betrieb: Journal `pegelSplit aktiv: ... pegelFix: 3 Namen da`.
- Aeltere Bestaetigungen: commit34 25.10. 20:36, commit35 25.10. 20:42, commit36 26.10. ~18:23, commit37 26.10. ~19:05.
- relStop (commit39) im Betrieb bestaetigt: beim Neustart am 30.10. um 06:40:18 stand im Journal `relStop SIGTERM: uplinkDetect uplink_state.json gespeichert` und `fertig in 0.01 s`.
- Veroeffentlicht, Anwendung offen: nur commit59 (laeuft). Jeder Patch prueft die Basis per sha16 und stoppt sonst mit klarer Meldung.

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
| commit44 pegelSplit | 1898fde2aa91d066 (30.10. 23:08 angewendet), 21790 Zeilen (Blob 891fd04f) |
| commit45 perfWsgi | d0f34851146d65b5 (31.10. 05:42), 21941 Zeilen, 1126150 B (Blob 223c51f4) |
| commit46 perf03Cache | 4594deab53d8ce7b (31.10. 07:31), 22185 Zeilen, 1137546 B (Blob 3697430b) |
| commit47 speedAsync | 74ac7bfd0eebd4e0 (31.10. 11:30), 22340 Zeilen, 1145572 B (Blob 7873cc17) |
| commit48 geoRelevanz | 334b60f2ed228831 |
| commit49 audioKern | 1dc1eedcb0c91342 (23580 Zeilen) |
| commit50 audioUi | 2a3625a3325653b1 (23774 Zeilen) |
| commit51 kartePop | 67d58079139cd373 |
| commit52 hbProblem | ab18872053f58871 |
| commit53 umweltFlach | 832787ef1c3b44bc |
| commit54 qrmRun | 7b81384b4af00883 |
| commit55 usvLesen | 86f712401eddab5f |
| commit56 usvAlarm | 35fbc0604b09c0dd |
| commit57 usvShutdown | **7d494c1a21e50e96** <- bestaetigter Pi-Stand (01.11. 06:27), 25247 Zeilen; commit58 aendert dashboard.py nicht |
| commit59 snFrei | 2d0412bbbecc25b3 (nur Platzhalter statt Seriennummern) <- Ziel, wird eingespielt |

### lage_pages.py (neu seit commit41: Seitenvorlagen aus dashboard.py, nur Text)

| nach Patch | sha16 | Inhalt |
|---|---|---|
| commit41 pagesSplit1 | e7b3bb1ea1a145d3 (361 Zeilen) | PAGE_ADSB |
| commit42 pagesSplit2 | 6a596584014df095 (2471 Zeilen) | + PAGE4, PAGE_SPEICHER, PAGE_UMWELT2, PAGE_PI, PAGE_MESH, PAGE_NEWS, PAGE_LUFT |
| commit43 pagesSplit3 | 231d4c309c1ae009 (4241 Zeilen) | + PAGE1, PAGE2, PAGE3, PAGE_LOKALE_ENERGIE |
| commit44 pegelSplit | 7f9fc0cf17d52644 (4480 Zeilen), Branch-Blob 1f38c694 | + PAGE_PEGEL |
| commit47 speedAsync | 1d33ae9fd78f53dc (4496 Zeilen, 205198 B, Blob f4e8129c) | measureDownload in PAGE_PI: 202 + Abfrage /api/speedtest |
| commit53 umweltFlach | a51d9b51a646813d | /umwelt flach (feste Reihenfolge, Erklaerungen hinter "i") |
| commit55 usvLesen | 495ee5ac809143c8 | USV-Kachel #usvCard auf /lokale-energie |
| commit56 usvAlarm | 92a37e6326f0900d | Knopf Audio-Pegel testen, Netzausfall-Anzeige |
| commit57 usvShutdown | **a9740c629a41806c** (4547 Zeilen) <- Pi-Stand (01.11.) | Kachel-Zeile Abschaltung (usvShut) |

Marker in dashboard.py (je genau 1x): relHygiene, perfKeep, sameOrigin, alarmFaden, relWatch, dbVis, mapUi, modDead, secXmlDash, wxSlot, meshBootQuiet, funkHarden2, kartevec, clockOff, ninaFix, hideTexts, longArchive, relStop, asyncMini, pagesSplit1, pagesSplit2, pagesSplit3, pegelSplit, perfWsgi (24; perfWsgi seit commit45); nach commit46 zusaetzlich perf03Cache (25); seit commit47 zusaetzlich speedAsync (26); commit48-57 dazu geoRelevanz, audioKern, audioUi, kartePop, hbProblem, umweltFlach, qrmRun, usvLesen, usvAlarm, usvShutdown = 36 Marker (auf der Pi bestaetigt 01.11.).

### weitere Dateien (Soll laut Apply-Skripten; auf der Pi gegenpruefen, nicht alle in dieser Sitzung erneut gelesen)

| Datei | sha16 Soll | aus Patch |
|---|---|---|
| database.py | 2754d0bdddca9400 | snFrei commit59 (Ziel; vorher Stand commit58, nur Platzhalter-Tausch) |
| lage_xml.py | f77305fc17ed2f77 | secXml |
| mesh_bridge.py | 3482f6e386cf26ce | bridgeCore commit22 |
| mesh_bridge_bayern.py | c1176b457346ae49 | bridgeCore commit22 |
| mesh_bridge_core.py | ddc134f29a6a8949 | bridgeCore commit22 |
| luft.py | 0ccae0834ab27f6d | laut Apply-Skript, Patch nicht einzeln zugeordnet |
| secret_util.py | ff8e2ac7049f4bde | secHard commit24 |
| tools/backup.sh | 5053f6b8a43a8638 | relBackup2 commit18b |
| Restore-Werkzeug | c0e305b8ea4d9007 | relBackup commit18 |
| health_check.py | 5a0156ff02d5960c | relHygiene commit19b |
| prepper_docs.py | 43032d218135e329 (bestaetigt 01.11., Generator 3) -> 2e1e23726611b2ec (commit59, Stick-Tabelle neutral) | docsVer commit38, dokuStand commit58, snFrei commit59 |
| prepper_sdr.py | 264ef34996e17753 (qrmLage commit54, bestaetigt 01.11.) -> b879ab56f4ac4736 (commit59: Seriennummern nur lokal, Selbsttests last-/uhrunabhaengig) | vorher 0900bfe6ba67e657 (commit47) |
| sdr_manager.py | 5a26efff608bf541 | snFrei commit59 (nur Platzhalter-Tausch) |
| prepper_evlog.py | 8bffd396972b60fa | evlFix commit54 |
| ups_manager.py | ef0b9e3d4bf42003 | usvLesen commit55 (neu) |
| sdr_serials.local.json | nur lokal auf der Pi, Rechte 600, nie im Repo | snFrei commit59 (legt das Apply-Skript an) |
| /etc/nut (ups.conf, upsd.users, upsmon.conf) | lokal, root:nut 640, Passwort zufaellig und nur lokal | usvNut commit55, usvShutdown commit57 |
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
| **46** | perf03Cache | PERF-03 Rest Punkt 1+2: /api/frequenz aus data_store, /pegel Stale-While-Revalidate | 240280cdf0624bf7a288c389e10b78eaaab48f49 |
| **47** | speedAsync + Aufraeumen + fullcheck 2.0.2 | PERF-03 Punkt 4 (Download-/Speedtest ohne Blockieren), .bak-Archiv, tote Zeilen prepper_sdr.py, ~ip-Rest, fullcheck Airspy-Seriennummer | 2448473c709e3909c87d021f3bd78000d60c4390 (apply-commit47.sh + fullcheck.sh 2.0.2) |
| **48** | geoRelevanz | Ortsbezug der BR24/ASA-Warntexte (INFO/WARNUNG/rot, Bestaetigung binnen 30 min); Vorfall-Sim 12/12 | 321ada77 |
| **49** | audioKern | Lautsprecher-Warteschlange KATASTROPHE > WARNUNG > INFO, Nachtruhe 22-07, Stumm max. 8 h | 871adf76ba1c8ba46b7222c8d286e19fe6a2b45a |
| **50** | audioUi | Audio-Kachel #audioBox auf /pi ueber der Sicherung | 4cb22e3acd7b37669c86201d3b720fbadd8300d7 |
| **51** | kartePop | Karten-Popup Mast/Linie, parallele Linien, /api/karte/hist | 7939001661af203ded69199354796aa23d268552 |
| **52** | hbProblem | Heartbeat Mesh 1 nur bei echtem Problem plus Entwarnung | f010d6fc5844b1db7e4e14e7f6db1138589c55ba |
| **53** | umweltFlach | /umwelt flach, feste Reihenfolge, Erklaerungen hinter "i", Abruf nur bei sichtbarem Tab | 296763b505abf9f5e1aa80536015a7328c1d591b |
| **54** | qrmLage + evlFix + qrmRun | QRM-Pause max. 6 h, Waechter "QRM steht"; Ereignis-Log verwirft Uhrsprung-Ereignisse; Anzeige QRM-Zustand | 6b89fe9e45597f2608f95f2046abe11ad9abd20f |
| **55** | usvNut + usvLesen | NUT nur lokal (127.0.0.1:3493), ups_manager.py, USV-Kachel, /api/usv (nur Anzeige, nie ein Befehl an die USV) | a6992b76cafcfe69c018b1918e63ed8a88eab7e8 |
| **56** | usvAlarm | Netzausfall: Gong + Ansage, zweite Ansage bei 5 min, Mesh-Punkt STROM, Probegong | 818c9b15ddafaea6568aa8da6d2e5c055c712b4e |
| **57** | usvShutdown | upsmon faehrt den Pi bei 20 % oder 5 min herunter, killpower; Dashboard zeigt nur an | 0ee72d3517bb589956c9a9aecf5eb0ee5dcde213 |
| **58** | dokuStand | Projektbeschreibung (prepper_docs.py Generator 3) auf Stand commit39-57 | 18e9eecca85c918b8c2a1bf6767db3f3b38cd342 |
| **59** | snFrei | Stick-/Airspy-Seriennummern aus allen veroeffentlichten Dateien entfernt (neutrale Platzhalter, Werte nur lokal in sdr_serials.local.json, 600), Neustart prepper-sdr + prepper-dashboard mit Stick-Zuordnungs-Pruefung | d1e54d4e11d80d2c07a72a63b957d807aa32b7cf (ersetzt 37eb40ad, der auf der Pi im Selbsttest stoppte) |

Fett = vom Auftrag "19b/22/27–35" erfasst, sowie die neuen Commits 38–59.

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
| 46 perf03Cache (dashboard.py Blob 3697430b; lage_pages.py unveraendert) | c3c11ecebcb1bab263a1a6f3cf626d206643da0a |
| 47 speedAsync (Blobs dashboard.py 7873cc17 / lage_pages.py f4e8129c / prepper_sdr.py 61c6fb87) | 5b533749294682a96833d35eab5a065cd515e62a |
| 48 geoRelevanz (dashboard.py Blob 1eeded24) | 5d08fd61 |
| 49 audioKern (Blob a9ea7226) | 1a4c731489fe16496fe371a6e92ad0c6ded39671 |
| 50 audioUi (Blob 39899a94) | b7984f6603a3a7ce00974cd0945ffd93a4370223 |
| 51 kartePop (Blob 30b055aa) | 5b0fd5d752399b82ca4b17a865ae7051d5228835 |
| 52 hbProblem (Blob 6d754df8) | 27b80df16a9a521432377830576f5b953efb1537 |
| 53 umweltFlach (Blobs ab583ab6 / 83e3d288) | 6b95c2d05805958c812f55493ff35232801edec2 |
| 54 qrmLage/evlFix/qrmRun (Blobs 08d24330 / 97ad0a2b / b5e4ab1f) | 7f01f7da897967575f82cc6280ef02ddce91837e |
| 55 usvLesen (Blobs dashboard 7edc28dd / lage_pages f9b49d26 / ups_manager c1c12ec8) | 7d3ea7590eec2af991dcd37a5c7ffa2f65444c14 |
| 56 usvAlarm (Blob dashboard 8bd9210c) | bb0fe7f3f1f84b8c58f2199bb50a09864ff61504 |
| 57 usvShutdown | 650639f05ffd238d5e1a4892f42a36b2d2f04b0f |
| 58 dokuStand (prepper_docs.py Blob 7b225dd7) | e64d28a456d69e9954487c98ee627a6060ab1263 |
| 59 snFrei (4 Dateien + dashboard.py, je max. 4 pro Push) | b5b0c631b0dd0c2d4dded33da0210804f7abb865 + b474d979a0c9038a923c41c2f7dbf635dd5dc0b2; Fix prepper_sdr.py e863b786a205a63a846941897365b4145f8f7a6b |

Aeltere Branch-Commits (secXml: lage_xml/database c7c27ed8…, requirements a2f411fa…, .gitignore 48a77020…, MOD-10-Aufraeumen archive/*, Audit-Doku eb48496f…): `git log` im Repo.

### Apply-Skripte (Groesse / sha256)

- apply-pagessplit1.sh (41): 47433 B, sha256 fff792932d760826005176faea15753928c26f14e304c7aae23e3de3155ac4c4
- apply-pagessplit2.sh (42): 53943 B, sha256 230b6d7a949fc4df56cfa09cdfab1365d606e74dc432655adcbdf9968b452aa0
- apply-pagessplit3.sh (43): 55022 B, sha256 89f18bc671afbe7121bef6134c5e0fdc9d9418bb0ad1b279fd1b64c5a931823b
- apply-pegelsplit.sh (44): 58782 B, sha256 d35ca97206613e336d7d9d30fcb012175c620a2631aa209b5c8ace45e8ad8d43
- apply-pipwaitress.sh (45a): 82984 B, sha256 d218e9b67652d9c53760673c8d2e2d5d40966c3b58d11207564f9a901d7641f3
- apply-perfwsgi.sh (45): 62882 B, sha256 60fd2672b0ffb0d4b9f1a8094616454e4a0c487caa1ac9ac7e4727f5fbf74860 (STOP, wenn waitress 3.0.2 nicht im venv ist)
- apply-commit47.sh (47): 189089 B, sha256 d4fae93cf10980aae09e263b7e4b87fae3266c970813ac4e216b690688a7b157 (STOP bei Mischstand oder fremder Basis einer der drei Dateien, perfWsgi nicht aktiv, Neustart-Sperre; Aufruf `bash /tmp/apply-commit47.sh commit47`, Trockenlauf mit `dry-run`)
- apply-perf03cache.sh (46): 66535 B, sha256 4c2a279431b4a59da7ccd57f40e4f950b4a67976f69b58e619942ee15a40fee0 (STOP bei fremder Basis, lage_pages.py ungleich 7f9fc0cf17d52644, perfWsgi nicht aktiv, Neustart-Sperre)

- apply-commit48.sh (48): 90486 B, sha256 fd4b622b703be85bc840bcf0c55c0deba231d5366a417304067933f771664f46
- apply-commit49.sh (49): 100044 B, sha256 7fef8f156e72e678db72d345ad5ebb98c6f20878e21687769b265d5df13c1cd5
- apply-commit50.sh (50): 142344 B, sha256 d8adc7e0953d290d31a3561f95f5889a647ec3d0b819d588456266e0b0e3d3bc
- apply-commit51.sh (51): 88011 B, sha256 df10b51538879ee561af10bedf9d1e9aae9c247320cc8f44cd8b2e5084c22bac
- apply-commit52.sh (52): 71700 B, sha256 d64cd2a6ec55480ae54625fbf7a0ffa9a9471495d6ec04cc508de41b9bb81bf9
- apply-commit53.sh (53): 130694 B, sha256 2cae60f0757db4ed086fc4817a0ef8f305901613159952b7f943fd232c680bf3
- apply-commit54.sh (54): 129027 B, sha256 45fc75941367dd94c351e5b4985ab4965d3c97e358d2c13514e57f38842125b7
- apply-commit55.sh (55): 132973 B, sha256 b158ff0fd47d012f802725d0e35731d7807bd69b080032c1da03837c580cd034
- apply-commit56.sh (56): 77182 B, sha256 5424e73c0387a969c3127b302f5b005e63b79236bd5d0b6421ceaab75c2d7bb8
- apply-commit57.sh (57): 85198 B, sha256 cbb0eb813ac369c6570986680d9ca0644af899c7869cc1168289f7ee4533478e
- apply-commit58.sh (58): 66206 B, sha256 253484a83988508cfa4416167d20a1d5882a446592f14dec235ebfe659c68ee3
- apply-commit59.sh (59): 58058 B, sha256 f70d332fa0f6105dcae9aa7296d58d96be37d9f827ca67133fb6c33fb06ca1b7 (gepinnt main d1e54d4e; Selbsttest-Gegenprobe alt/neu zur selben Uhr; startet prepper-sdr und prepper-dashboard neu, Neustart-Sperre)

- apply-docsver.sh (38): 50788 B, sha256 c1b0549ff7385040c9a8067c5500635f2a0733cbe0984158e2b2b347c567fd04
- apply-relstop.sh (39): 41179 B, sha256 1667ff4a6affee7f15f2ecd18814d2ee7f47ff944b03f832f3feadb2dcdad957
- apply-asyncmini.sh (40): 35404 B, sha256 2316fba9d9e471110ff80907e1adc5b2e783c5d1f3e1c6139026fc633a089add

Aufruf je Patch: `bash /tmp/apply-<name>.sh commitNN dry-run` (erst Trockenlauf), dann ohne `dry-run`. Ein sudo-Prompt, nur der Dienst prepper-dashboard wird neu gestartet. Ab commit39 gilt die Neustart-Sperre HH:55–HH:04 zu jeder Stunde (vorher nur um die Wetter-Slots 0,3,…,21 Uhr) – dann ab HH:05 neu starten.

## 4. Erledigte Audit-IDs (Patches veroeffentlicht)

REL-01, REL-02 (30), REL-03 (18/18b), REL-04, REL-09 (19/19b), REL-05, REL-06 (25/25b), REL-07 (23), MOD-02 (20), MOD-04 Stufe 1 (22), MOD-08 (32), MOD-09 (28), MOD-10 (Repo-Aufraeumen, Branch-Commits), PERF-02 (29), PERF-03 Backup-Teil (18), PERF-05 (21), PERF-06 (23), SEC-01 Code-Seite (26), SEC-04, SEC-12 (26), SEC-05 (28), SEC-09/10/11 (24, 31x, 33), SEC-13 Teil: Chart.js lokal (19). SEC-02/SEC-03 (Laufzeitdaten/.gitignore) laut Branch-Commits behandelt – in dieser Sitzung nicht neu geprueft.
REL-10 Teil 3 (39 relStop, im Betrieb bestaetigt). INT-3 (toter scanner_mode_set-Altcode mit sudo systemctl) erledigt durch commit32 modDead; am Stand f8977a31 gibt es kein `sudo systemctl` mehr im Dashboard.
PERF-01 (45a/45, angewendet 31.10. 00:13 bzw. 05:42): waitress 3.0.2, 8 Arbeitsfaeden, ein Prozess, Bind 0.0.0.0:5000, Unit unveraendert. Messung nach dem Einspielen: Faeden gesamt 27, unter 48 parallelen Anfragen fest; /pi-Median 0,196 s direkt nach dem Neustart, eingeschwungen 0,183-0,190 s (Werkzeug vorher 0,177 s; kein Gewinn bei Einzelanfragen erwartet, Ziel war feste Fadenzahl und Produktions-Server). Restrisiko: mehr als 8 gleichzeitig lange Anfragen stauen sich; dauert das 180 s, startet relWatch neu (betrifft PERF-03 Rest).
MOD-06/07 teilweise: 13 Seitenvorlagen in lage_pages.py (41-44), weitere Vorlagen und Code-Module offen. Befund NameError `last_pegel_mesh_auto` behoben (44 pegelFix; Sim-Nachweis: eine Pegel-Meldung pro Wetter-Slot wie vorher, keine zusaetzliche Sendung).
Zusatz ohne Audit-ID: commit27 perfKeep, 31 dbVis, 31b mapUi, 34 wxSlot (Wetter-Slot, aus Pi-Journal), 35 clockOff (Uhr-Kachel), 36 ninaFix (NINA-TLS), 37 hideTexts (Lage-Texte), 38 docsVer (Docs-Version), 40 asyncMini (async-Minifix), fullcheck.sh 2.0.1/2.0.2 (read-only Pruefskript), 47 Aufraeumen (.bak-Archiv, tote Zeilen prepper_sdr.py, ~ip-Rest).
PERF-03 vollstaendig bis auf Punkt 3: Punkt 1+2 (46, angewendet 31.10. 07:31), Punkt 4 (47 speedAsync, angewendet 31.10. 11:30): /api/download_test und POST /api/speedtest?wait=1 starten die Messung im Hintergrund und antworten sofort mit 202 + Abfrage ueber /api/speedtest; Ergebnis der letzten 5 min direkt wie bisher; /api/backup/restore unveraendert.

Zusatz ohne Audit-ID (commit48-59): geoRelevanz (48), Lautsprecher audioKern/audioUi (49/50), kartePop (51), hbProblem (52), umweltFlach (53), QRM-Fixes + Ereignis-Log (54), USV NUT/Kachel/Ansage/Abschaltung (55-57), dokuStand (58). Tests je Patch: Guard mit Mutationstest 0 uebersehen (mit und ohne node), py_compile System- und venv-Python, Sim-Kette auf Port 5093 (normal + Wiederholung idempotent, Rollback erzwungen, Manipulation, fremde Basis, Mischstand, Neustart-Sperre), Smoke aller Seiten/APIs.
SEC-03-Naehe (Datenhygiene): commit59 snFrei entfernt Stick-/Airspy-Seriennummern aus allen veroeffentlichten Programmdateien und der Doku (Werte nur lokal, Rechte 600); geprueft gegen die echten Werte lokal, ohne sie auszugeben. Selbsttests seither unabhaengig von Pi-Last und Uhrzeit (Sim zu 06:30, 23:30, 02:30, 03:30, 05:30, unter Last).

## 5. Bewusst offen (Entscheidung Frank)

SEC-01 (nur Code-Seite erledigt, Rest bewusst offen), SEC-06, SEC-08.

## 6. Noch offen

- SEC-07; SEC-13 Rest
- PERF-03 Punkt 3 (/mesh, /mesh2; laut Messung schnell, nur bei Bridge-Haenger relevant): offen, braucht Freigabe.
- PERF-04, PERF-07, PERF-08
- REL-08
- REL-10 Teil 1 (NINA/DWD-Sofortrunde beim Start, vor dem ersten Voll-Update): gemessen, nicht noetig (first_update_s 16,9 s), nicht gebaut - Entscheidung Frank 31.10. Messung auf der Pi 31.10. 12:55 (/api/sysboot/status): first_update_s 16,9 s (unter der 30-s-Schwelle aus dem Plan), Alarm-Faden ok, NINA und DWD frisch, alle Faeden ok, Watchdog scharf, slow_n 2 (/pi 5,5 s, /luft 3,1 s, Einzelfaelle). Plan bleibt in der Sandbox (`/workspace/rel10/`), falls sich das Erst-Update spaeter deutlich verlaengert.
- REL-10 Teil 2 (network-online.target nicht blockierend, Wait-Online-Zeitlimit): offen und freigabepflichtig; eigener Patch im Bereich system (Drop-in), braucht Pi-Werte aus systemd-analyze.
- MOD-01, MOD-03, MOD-05; MOD-06, MOD-07 (Seitenvorlagen in Schritten 41-44 begonnen, Rest offen)
- fullcheck 2.0.2 (seit 31.10. 11:30): 98/100; einziger HINWEIS: Stick 2 (hobby) nicht am USB-Bus. Laut Frank ist der Stick NICHT abgezogen - der Hinweis wird untersucht (moeglicher Fehlalarm der Erkennung; Seriennummern gehoeren nicht in dieses Repo, seit commit59 auch nicht mehr in den Programmdateien).
- commit59 snFrei: Ergebnis des Einspielens auf der Pi steht aus (erwartet: Neustart prepper-sdr + prepper-dashboard, Stick-Zuordnung gleich, Selbsttests ok).
- USV: echter Abschalttest (Netzstecker ziehen) nur mit Frank vor Ort, nie per Befehl; SoH-Basis lernt die ersten 14 Tage.
- Seiten-Aufraeumen wie /umwelt: commit60 (alle Seiten ausser /umwelt, /funk, /karte) und commit61 (/funk, /karte) freigegeben, in Arbeit.
- Aufraeumen: erledigt mit commit47 (31.10. 11:30): Archiv `bak-archiv/20261031-112144` (4 Dateien, 3,2 MB; je Datei und Patch bleiben die 3 neuesten Sicherungen im Projektordner), 139 tote Zeilen in prepper_sdr.py entfernt (prepper-sdr laeuft bis zu seinem naechsten Neustart mit der gleichwertigen alten Fassung). Rueckweg: Dateien aus dem Archiv zurueckverschieben.
- Befund am Rande: funk_health.py und funk_page.py machen `from dashboard import fetch_mesh_status`. Weil dashboard.py als Hauptprogramm laeuft, laedt das beim ersten Aufruf dashboard.py ein zweites Mal als Modul `dashboard`. Nicht geaendert, nur gemeldet.
- gepinnte Zwischenstelle certs/sectigo-e36.pem: noch ca. 3434 Tage gueltig (Stand 26.10.); entfaellt, sobald warnung.bund.de die Kette wieder vollstaendig sendet.
- `~ip` im venv: erledigt mit commit47 (ins Archiv `bak-archiv/20261031-112144/venv-rest/` verschoben, nicht geloescht).

## 7. Hinweise fuer den Wiedereinstieg

- Arbeitsordner auf der Box: `/workspace/<patchname>` (`wxslot`, `clockoff`, `bridges`, `relclock`, …) mit `mk/` (Edits, Block, Konfig, apply-*.sh), `src2/` (Pruefprogramm `guard_*.py`), `sim/` (Simulationen), `testout/`. Werkzeuge: `/workspace/lib/mk_apply_dash.py` (Apply-Generator), `/workspace/lib/run_sim_dash.sh`, `/workspace/lib/chain_dash.sh`. Fortschritt: `/workspace/rel01/PROGRESS.md`. Standard: `/workspace/audit-run/PATCH_STANDARD.md`.
- Naechster Patch (commit60) baut auf dem Zielstand commit59 auf: dashboard.py `2d0412bbbecc25b3`, lage_pages.py `a9740c629a41806c`, prepper_sdr.py `b879ab56f4ac4736`, sdr_manager.py `5a26efff608bf541`, database.py `2754d0bdddca9400`, prepper_docs.py `2e1e23726611b2ec`, ups_manager.py `ef0b9e3d4bf42003`, prepper_evlog.py `8bffd396972b60fa`; 36 Marker. Werkzeuge commit55-59: `/workspace/usv/c55` ... `/workspace/usv/c59` (mk/, sim/), Fortschritt `/workspace/usv/PROGRESS.md`.
- Sims nur auf Port 5093 (NUT-Attrappe 3494), immer nur eine gleichzeitig, keine Screenshots; Sim-Reste nur per simkill.sh beenden. Seit commit59 laufen Sims zusaetzlich zu mehreren Uhrzeiten (libfaketime nur fuer die Selbsttests) und unter Last.
- Kleine Fixes Docs-Version, REL-10 Teil 3, async-Minifix und INT-3 sind erledigt (30.10.).
- Modul-Aufteilung laeuft (commit41-44: 13 Seitenvorlagen, dashboard.py von 26046 auf 21790 Zeilen). Aufraeumen in commit47. PERF-01 erledigt (commit45 perfWsgi angewendet 31.10. 05:42).
- **Freigabe von Frank noetig vor:** REL-10 Teil 2, MOD-05, MOD-06, MOD-07, PERF-03 Punkt 3, PERF-04.
- Offene Beobachtung: fehlende Mesh-Meldungen werden vom anderen Worker untersucht (nicht Teil dieser Patches).

## 8. Dauerregeln

- Keine Schluessel/Keys, keine Provider-Aktionen (z. B. Accounts, Bestellungen, Tarife).
- Kein Eingriff in die Firewall.
- Keine Secrets und keine Geraete-Seriennummern in Repos, Dateien oder Berichten.
- Patch-Standard: strikter sha16-Basis-Check, Trockenlauf + idempotent, Backups `*.bak-<name>-JJJJMMTT-HHMMSS` (3 behalten), atomare Schreibvorgaenge, AST-Guard mit Mutationstest ohne node, py_compile mit System- und venv-Python, Sandbox-Selbsttests, nur betroffene Dienste neu starten, Smoke-Test aller Seiten/APIs, Selbsttests uhr-/lastunabhaengig mit Gegenprobe alter Stand zur selben Uhr, Rollback mit klarer STOP-Meldung, ein sudo-Prompt, neue Docs-Version nur wenn prepper_docs.py im Umfang.
- Hoechstens 4 Dateien pro Push. Neustart-Sperre HH:55–HH:04.
- Sims nur auf Port 5093; Veroeffentlichung: prepper-patches (main) bekommt `apply-<name>.sh`, Branch kaeswasser-lage-monitor bekommt `dashboard.py` (und `lage_pages.py`); danach Raw-Pruefung (cmp, sha256, bash -n) gegen den festgenagelten Commit.
