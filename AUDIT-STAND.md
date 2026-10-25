# AUDIT-STAND – Prepper-Dashboard (BND-Prepper)

Stand: Sonntag 25.10.2026, 20:45 Uhr (Berlin), aktualisiert nach Anwendung von commit34 und commit35. Keine Secrets in dieser Datei.
Geschrieben vom Ausführungs-Agenten (Grok Bot) fuer Frank. Hintergrund: Frank t822u – Kontingent geht zu Ende, clockOff (commit35) ist bis naechsten Samstag die letzte Audit-Verbesserung.

Host: BND-Prepper, Debian 13 aarch64, systemd 257, Python 3.13, Port 5000, Benutzer fmg, Projekt `/home/fmg/prepper-dashboard`, kein node auf der Pi.
Audit-Dokument: `SECURITY_AND_PERFORMANCE_AUDIT.md` (41 Befunde: SEC-01..13, PERF-01..08, REL-01..10, MOD-01..10).

## 1. Ehrlicher Hinweis zur Genauigkeit

- Veroeffentlicht (Repos) und Angewendet (Pi) sind zwei Dinge. Die Hashes unten sind die **Soll-Werte aus den Patches**. Was auf der Pi wirklich liegt, muss dort gelesen werden:

      cd /home/fmg/prepper-dashboard && sha256sum *.py tools/*.sh | cut -c1-16,65-

  (erste 16 Zeichen je Datei mit dem Soll vergleichen).
- Bestaetigt angewendet auf der Pi (Frank-Ausgaben, 25.10.2026): bis einschliesslich commit35 (dashboard.py `1831e7cd923396d1`, 25479 Zeilen; commit34 20:36, commit35 20:42, je alle Pruefungen OK).
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
| commit35 clockOff | **1831e7cd923396d1** <- bestaetigter Pi-Stand (25.10. 20:42), gleich Branch kaeswasser-lage-monitor |

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
| prepper_docs.py | 609f0a7f00ab586b | relHygiene (Docs-Version seitdem nicht geaendert) |
| funk_health | f1b16a5f9bc7317c | relHygiene (aelterer Stand) |
| mesh_hang_watchdog | 1518dbd9931c5e96 | relHygiene (aelterer Stand) |
| lage_clock.py | sha256 beginnt c909aea1148518fe | relClock commit25 |
| lage_disk.py | sha256 beginnt 4b6b35ab7c97dfc7 | relClock; relClock2 (25b) kann abweichen |

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

Fett = vom Auftrag "19b/22/27–35" erfasst.

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

Aeltere Branch-Commits (secXml: lage_xml/database c7c27ed8…, requirements a2f411fa…, .gitignore 48a77020…, MOD-10-Aufraeumen archive/*, Audit-Doku eb48496f…): `git log` im Repo.

### Apply-Skripte (Groesse / sha256 der letzten drei)

- apply-secxmldash.sh (33): 49463 B, sha256 9e9105c2feefb6f30a3204392b34cd93d8f418704a0ad788851bc9155861d642
- apply-wxslot.sh (34): 79610 B, sha256 72c80c93b1e134e1ca215e4f749f150859dc4c09e093921e1b23e6a7fc6b932c
- apply-clockoff.sh (35): 61369 B, sha256 d23efde416a8fe4e03cfab8e0ecfd84cac24cce37f67f652f690e8cd005ae16b

Aufruf je Patch: `bash /tmp/apply-<name>.sh commitNN dry-run` (erst Trockenlauf), dann ohne `dry-run`. Ein sudo-Prompt, nur der Dienst prepper-dashboard wird neu gestartet. wxSlot und clockOff stoppen mit klarer Meldung, wenn der Neustart in die Wetter-Slot-Zeit fallen wuerde (HH:55–HH:04 um 0,3,…,21 Uhr; HH:55–HH:59 der Slot-Stunden) – dann einfach nach der Zeit neu starten.

## 4. Erledigte Audit-IDs (Patches veroeffentlicht)

REL-01, REL-02 (30), REL-03 (18/18b), REL-04, REL-09 (19/19b), REL-05, REL-06 (25/25b), REL-07 (23), MOD-02 (20), MOD-04 Stufe 1 (22), MOD-08 (32), MOD-09 (28), MOD-10 (Repo-Aufraeumen, Branch-Commits), PERF-02 (29), PERF-03 Backup-Teil (18), PERF-05 (21), PERF-06 (23), SEC-01 Code-Seite (26), SEC-04, SEC-12 (26), SEC-05 (28), SEC-09/10/11 (24, 31x, 33), SEC-13 Teil: Chart.js lokal (19). SEC-02/SEC-03 (Laufzeitdaten/.gitignore) laut Branch-Commits behandelt – in dieser Sitzung nicht neu geprueft.
Zusatz ohne Audit-ID: commit27 perfKeep, 31 dbVis, 31b mapUi, 34 wxSlot (Wetter-Slot, aus Pi-Journal), 35 clockOff (Uhr-Kachel).

## 5. Bewusst offen (Entscheidung Frank)

SEC-01 (nur Code-Seite erledigt, Rest bewusst offen), SEC-06, SEC-08.

## 6. Noch offen

- SEC-07; SEC-13 Rest
- PERF-01, PERF-03 (Rest), PERF-04, PERF-07, PERF-08
- REL-08, REL-10
- MOD-01, MOD-03, MOD-05, MOD-06, MOD-07
- async-Minifix, INT-3
- Docs-Version: prepper_docs.py nennt noch "Stratum Offset (ntplib)" an 3 Stellen (~Zeilen 138/278/603). Ersatztext liegt in `/workspace/clockoff/DOCS_TEXT.md`.
- ca. 250 alte `.bak`-Dateien im Projektordner (Patches behalten je 3 eigene Backups; Altbestand aufraeumen)
- ca. 130 tote Zeilen in prepper_sdr.py
- root-eigenes `~ip` im venv (stoert pip; als root pruefen/entfernen)

## 7. Hinweise fuer den Wiedereinstieg

- Arbeitsordner auf der Box: `/workspace/<patchname>` (`wxslot`, `clockoff`, `bridges`, `relclock`, …) mit `mk/` (Edits, Block, Konfig, apply-*.sh), `src2/` (Pruefprogramm `guard_*.py`), `sim/` (Simulationen), `testout/`. Werkzeuge: `/workspace/lib/mk_apply_dash.py` (Apply-Generator), `/workspace/lib/run_sim_dash.sh`, `/workspace/lib/chain_dash.sh`. Fortschritt: `/workspace/rel01/PROGRESS.md`. Standard: `/workspace/audit-run/PATCH_STANDARD.md`.
- Naechster Patch baut auf dashboard.py `1831e7cd923396d1` (nach commit35) auf; Basis-Hash im Generator-Config (`cfg_*.py`) anpassen.
- Simulationen nur auf Port 5093, immer nur eine gleichzeitig, keine Screenshots.
- Empfohlene Reihenfolge nach der Pause: (1) auf der Pi pruefen, ob der Wetter-Slot (Wetter, Pegel, Heartbeat alle 3 h) ohne Luecke kam und die Kachel "Zeit-Offset" stimmt (curl -s http://127.0.0.1:5000/api/sysboot/status, Journal grep wxSlot); (2) kleine Fixes: Docs-Version (DOCS_TEXT.md), REL-10, async-Minifix, INT-3; (3) Aufraeumen (.bak, tote Zeilen, ~ip); (4) groessere Umbauten nur nach Freigabe.
- **Freigabe von Frank noetig vor:** PERF-01, MOD-05, MOD-06, MOD-07, PERF-03 (Rest), PERF-04.
- Offene Beobachtung: fehlende Mesh-Meldungen werden vom anderen Worker untersucht (nicht Teil dieser Patches).

## 8. Dauerregeln

- Keine Schluessel/Keys, keine Provider-Aktionen (z. B. Accounts, Bestellungen, Tarife).
- Kein Eingriff in die Firewall.
- Keine Secrets in Repos, Dateien oder Berichten.
- Patch-Standard: strikter sha16-Basis-Check, Trockenlauf + idempotent, Backups `*.bak-<name>-JJJJMMTT-HHMMSS` (3 behalten), atomare Schreibvorgaenge, AST-Guard mit Mutationstest ohne node, py_compile mit System- und venv-Python, Sandbox-Selbsttests, nur betroffene Dienste neu starten, Smoke-Test aller 26 Seiten/APIs, Rollback mit klarer STOP-Meldung, ein sudo-Prompt, neue Docs-Version nur wenn prepper_docs.py im Umfang.
- Sims nur auf Port 5093; Veroeffentlichung: prepper-patches (main) bekommt `apply-<name>.sh`, Branch kaeswasser-lage-monitor bekommt `dashboard.py`; danach Raw-Pruefung (cmp, sha256, bash -n) gegen den festgenagelten Commit.
