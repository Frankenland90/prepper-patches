# commit64 stimmeDe — Prüfbericht

Nicht veröffentlicht. Nicht gemergt. Nicht auf kaeswasser-lage-monitor oder main gepusht. Kein Pi-Zugriff. Kein apt. Keine echte Wiedergabe, kein Alarm, kein Mesh, kein Telegram.

Frank hat commit63 am 06.11.2026 um 22:06 Berlin auf dem Pi installiert. Dieser Patch ist der Folgepatch dazu und ersetzt commit63 nicht. Der Deployment-Branch bleibt a86c923116a43b0e942dbb99721db8320864886f.

## Artefakt

- Datei: /opt/cursor/artifacts/apply-commit64.sh
- sha256: 372d281d60a1dec55e80caf966cbb3af7069e13efae4c7e9b1073514f2e94ccf
- Größe: 2078850 Bytes
- bash -n: ok
- Das Skript ruft kein apt auf.
- apply-commit63.sh ist unverändert: sha256 3ba47f58312973d2212f8c63bf471227b41b53913a4163c1dac0a0530a51f8d4, 2676712 Bytes.

## Review

- Branch: cursor/mbrola-stimme-d32b
- Commit: 5c1b9901f0d6a54a469041f87ab563fa23f94724
- Gestapelte Basis: cursor/usv-spitzboden-eg-d32b b4ec9275d39bf01f952eeff9f62ba92e86b837bc
- Der Pull-Request zeigt nur diesen einen Commit gegen den commit63-Reviewbranch.
- Deployment-Branch danach unverändert a86c923, main unverändert 0a6c782.

## Bestätigte Basis auf dem Pi (commit63, trim)

| Datei | sha256 | sha16 |
|---|---|---|
| dashboard.py | 8a055ad3ed0619f681e2575c5ad588c3a28330eba1c00daab46d1cde46e28908 | 8a055ad3ed0619f6 |
| ups_manager.py | b2e491e36a9a1861de4c609f80a613f9b824e4f6f52319c50e5c5a87252ddcf8 | b2e491e36a9a1861 |
| lage_pages.py trim | 6b10e3bae7118d9519760b492220e88a5caf2e9dc99e9ed8db096eb911d0e778 | 6b10e3bae7118d95 |
| prepper_docs.py | 8f9983737e5217a4dbaecbc8764d6889cff10f0a82a41fe7b97e1bf9671e3751 | 8f9983737e5217a4 |

Die ungekürzte commit63-Fassung von lage_pages.py (d268d324f4fd55a53cb7ee1919e3fb399e2c4ca0a7733780c9bf977b0fee2fca) wird akzeptiert und ebenfalls nicht geschrieben. Jeder andere Hash, auch die alte commit62-Kuerzung 5185cfefaf5dbc1c, stoppt vor jeder Aenderung.

## Zielhashes

| Datei | sha256 | sha16 |
|---|---|---|
| dashboard.py | 5858908eaf6498bbcb737ad4791adb0bba0e4c7f4be0657f0bb31cdbef157a1d | 5858908eaf6498bb |
| prepper_docs.py | 36804387c50cba2b2021c71eaef1babc7aee85ebb0042e0849fa2267013d9937 | 36804387c50cba2b |
| lage_pages.py | unverändert, auf dem Pi 6b10e3bae7118d95 | 6b10e3bae7118d95 |
| ups_manager.py | unverändert b2e491e36a9a1861 | b2e491e36a9a1861 |

## Stimme

Gewählt ist mb-de7. Das ist die deutsche Frauenstimme, die Debian als Paket mbrola-de7 ausliefert (trixie, non-free, Architecture all) und die espeak-ng unter dem Namen mb-de7 anspricht. Das Programm mbrola 3.3+dfsg-9 liegt im offiziellen Archiv trixie contrib für arm64. mb-de8 ist bairisch und nicht diese Standardstimme. Es werden keine fremden Binärdateien mitgeliefert. Auf dem Pi wird nichts davon als vorhanden angenommen.

Reihenfolge, nur lokal, ohne Netz: mb-de7, wenn Programm und Datei /usr/share/mbrola/de7/de7 da sind; sonst espeak-ng -v de; sonst espeak -v de. Eine fehlende oder zu kleine WAV-Datei ist keine Ansage. Abbruch beendet auch ein Kind namens mbrola und spricht nicht weiter. Reguläre Ansage, USV-Ansage und der bestehende Test benutzen denselben Weg. Der Test setzt mesh auf false.

Unverändert: Vorrang KATASTROPHE vor WARNUNG vor INFO, Stumm, Nachtruhe 22–07, Dedup 6 h, Budgets, Sirene und Gong, gespeicherte Lautstärke 80 %, Katastrophe 100 % und danach zurück, USV-Alarm, Abschaltung bei 20 % oder 5 min, OB-Erkennung. Der Ausgabeweg bleibt pulse, dann ALSA default, dann plughw der Kopfhörerbuchse. PipeWire wird nicht umkonfiguriert.

## Vor einer späteren Paketinstallation getrennt zu bestätigen

Das Apply installiert nichts und ändert keine Paketquellen.

1. Archive contrib und non-free für Debian 13.
2. Paket mbrola aus trixie contrib, arm64, 3.3+dfsg-9.
3. Paket mbrola-de7 aus non-free, Architecture all.
4. apt nicht in der Neustart-Sperre HH:50 bis HH:04 und mit 15 Minuten Vorlauf vor einem Neustart.

Ohne diese Pakete bleibt die bisherige espeak-ng-Stimme. Ein fehlendes MBROLA macht die Ansage nicht stumm.

## Tests

- py_compile von dashboard.py und prepper_docs.py.
- Import von dashboard.py gegen die bestätigte gekürzte lage_pages.py. Dabei läuft der Audiokern-Selbsttest mit Ersatzprozessen: MBROLA fehlt, MBROLA-Fehler, zu kleine und leere Datei, Zeitlimit mit Rückfall, Abbruch ohne zweite Stimme, beide Synthesen kaputt, nur espeak wenn espeak-ng fehlt. Zusätzlich die bisherigen Fälle für Dedup, Lautstärke 100 % dann zurück, Ausgabeweg und Test ohne Mesh. teil4-, usvAlarm- und usvShutdown-Selbsttest bleiben ok. ups_manager.selftest ok.
- Guard auf trim und auf full: ok.
- Mutationstest im Apply, Variante trim: 10/10, 0 übersehen.
- Trockenlauf: Baum unverändert, kein Neustart.
- Normal auf der bestätigten Kürzung: ein Neustart nur prepper-dashboard, Zielhashes, lage_pages.py bleibt 6b10e3bae7118d95, scenario_note und profile_text bleiben weg, 14 Seiten und 16 APIs wie vorher. Zwei Startbildschirm-Antworten, dann die echte Seite.
- Zweiter Lauf: keine Änderung, kein zweiter Neustart.
- Ungekürzte commit63-Basis: lage_pages.py bleibt d268d324f4fd55a5, Profilzeilen bleiben.
- Unbekannte lage_pages.py: STOP vor jeder Änderung.
- dashboard.py noch auf commit62: STOP, erst commit63.
- Sperre 21:51: STOP vor dem Ersetzen. Trockenlauf um 12:50 schreibt nicht und meldet die Sperre.
- Fehlerseite nach dem Neustart: Rollback auf die commit63-Hashes, Kürzung bleibt, zweiter Neustart nur für die Rücknahme.
- Sandbox nur Port 5093. Keine echten Geräte.

In dieser Umgebung sind System-Python und die Sim-venv derselbe Interpreter. espeak-ng, espeak, aplay, amixer und mbrola sind hier nicht installiert. Die Selbsttests ersetzen die Prozesse. An einem Lautsprecher wurde nichts abgespielt. Ob PipeWire auf dem Pi eine direkte aplay-Ausgabe weiter blockiert, ist derselbe bestehende Weg und hier nicht hörbar geprüft.

Die Projektbeschreibung im Generator prepper_docs.py ist angepasst. Das Apply schreibt sie als Datei, erzeugt aber docs/ nicht neu. Die Kachel auf /pi übernimmt den Text, wenn danach wie bisher python3 prepper_docs.py läuft.

## Offene Punkte, keine weiteren Schritte

Eine echte Ansage an der analogen Buchse ist nicht geprüft. Die Pakete mbrola und mbrola-de7 sind nicht installiert und nicht freigegeben. Bis zu einer weiteren Freigabe wird nichts veröffentlicht, nichts gemergt und nichts auf dem Pi ausgeführt.
