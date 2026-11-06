# pinnebergRolle Stufe 1 — Prüfbericht

Nicht veröffentlicht. Nicht gemergt. Nicht auf kaeswasser-lage-monitor oder main gepusht. Kein Pi-Zugriff. Kein apt. Kein Empfangsprogramm. Kein Bias-Tee. Nichts gesendet.

Commit 64 bleibt das vorherige Artefakt: `/opt/cursor/artifacts/apply-commit64.sh`, sha256 `372d281d60a1dec55e80caf966cbb3af7069e13efae4c7e9b1073514f2e94ccf`, 2078850 Bytes. `apply-commit63.sh` bleibt `3ba47f58312973d2212f8c63bf471227b41b53913a4163c1dac0a0530a51f8d4`.

Die Patchnummer ist offen. Sie ist nicht 65. 65 bleibt für CSP frei. Danach kämen CSP/Dateirechte und ntfy, beides ist nicht gebaut.

## Artefakt

- Datei: /opt/cursor/artifacts/apply-pinneberg-rolle.sh
- sha256: 6c4c64e24e5143fa1af1abb672d14b49e5327602e9ee85169d08903661b78ff1
- Größe: 3132201 Bytes
- bash -n: ok
- Rollendatei pinneberg_rolle.json sha256: e091123291a188749e7f6ea28f72672ae3bc314120a45bb5da8ed0fa08e58e8f
- Das Skript ruft kein apt auf und startet prepper-sdr nicht neu.

## Review

- Branch: cursor/pinneberg-rolle-d32b
- Commit: 824fe169612e3fb641771dc45a6a16a7ed83a89a
- Gestapelte Basis: cursor/mbrola-stimme-d32b, commit64 5c1b9901f0d6a54a469041f87ab563fa23f94724
- Deployment-Branch danach unverändert a86c923

## Basis und Ziele

Voraussetzung ist commit64. dashboard.py muss `5858908eaf6498bb` sein, sonst STOP. Ein Stand von commit63 (`8a055ad3ed0619f6`) wird abgelehnt.

| Datei | Basis sha256 | Ziel sha256 |
|---|---|---|
| dashboard.py | 5858908eaf6498bbcb737ad4791adb0bba0e4c7f4be0657f0bb31cdbef157a1d | 6d9fe2860fc636713461fd22b78de03941e23d167b7475e608f773fd0e5650b9 |
| prepper_docs.py | 36804387c50cba2b2021c71eaef1babc7aee85ebb0042e0849fa2267013d9937 | c26252d54344ca25875a5cf3e79b31df879af18ff9c504ec008a8ffff0080910 |
| prepper_sdr.py | b879ab56f4ac47367afec20c904d3f1e274bc5ed154cd434a25b3bb8ca84b0bb | 533b6f9db8da0bcb73ca0e956bfc7a2edfade287375aa4eaf21f10a4ab37fb32 |
| pinneberg_rolle.py | fehlt | 981cacdbf5a81348f9b32f67ac1c9ca27382af916d340c3b7773a84e87df06f5 |
| lage_pages.py trim | 6b10e3bae7118d9519760b492220e88a5caf2e9dc99e9ed8db096eb911d0e778 | unverändert |
| ups_manager.py | b2e491e36a9a1861de4c609f80a613f9b824e4f6f52319c50e5c5a87252ddcf8 | unverändert |

Die ungekürzte Fassung d268d324f4fd55a5 bleibt ebenfalls unverändert, wenn sie vorliegt.

## Was Stufe 1 tut

DDH47 Pinneberg sendet auf 147,3 kHz, F1B, 50 Baud, Shift 85 Hz, also 42,5 Hz je Seite. Der SpyVerter mit 120-MHz-Oszillator legt das auf 120,1473 MHz. 1900 Hz ist ein möglicher späterer Tonlagen-Arbeitspunkt eines USB-Decoders und kein Teil der Sendefrequenz. Er wird nicht addiert. Eine Ausbreitungszeit von etwa einer Millisekunde belegt die Herkunft nicht.

Der Inhalt wäre maritime Zahlengruppen für die Schifffahrt. Diese Stufe dekodiert nichts und verspricht keinen Empfang in Franken. Antenne und SpyVerter sind angeschlossen, der SpyVerter wird extern per USB versorgt. Ob das Langwellensignal ankommt, ist nicht gemessen. Ein Bias-Tee wird nicht eingeschaltet.

Sobald die Rollendatei gilt und prepper-sdr sie lädt, ist Stick 3 nur noch für diesen Empfang vorgesehen: kein APRS, kein RDS, keine 10C-Prüfung, keine Kalibrierung auf diesem Stick. Stick 2 behält 433, QRM, Meteor und die Kalibrierung um 04 h und übernimmt APRS nicht, auch wenn Stick 3 fehlt. Airspy bleibt 11D, ohne Retune und ohne Gain-Änderung.

Anzeige dieser Stufe: aus, STOP oder „reserviert, Empfang nicht gestartet“. Die Wörter kein Signal, lernt und empfängt werden nicht benutzt. Ein unklarer USB-Stand, eine doppelte Seriennummer oder eine Kollision mit einer anderen Rolle ergibt STOP. Es wird kein anderer Stick geöffnet. GET /api/pinneberg gibt keine Seriennummer aus. Replay-Text, der leer, zu alt, unleserlich oder wie eine Warnung aussieht, bleibt ohne Alarm.

Das Apply schreibt die Dateien und startet nur prepper-dashboard neu. Der laufende prepper-sdr-Prozess behält bis zu einem späteren eigenen Neustart das bisherige APRS. Diesen Neustart führt das Skript nicht aus.

## Spätere Stufen, nicht in diesem Patch

1. Diese Stufe: Rolle, Preflight, Anzeige, kein Programm.
2. Danach, erst nach eigener Freigabe: nur lesendes Spektrum bei 120,1473 MHz, noch ohne Decoder und ohne 1900-Hz-Annahme.
3. Danach ein kopfloser Decoder. Debian 13 arm64 liefert rtl-sdr 2.0.2-2+b1 und fldigi 4.2.06-1+deb13u1 aus dem offiziellen Archiv. rtl_fm demoduliert schmalbandiges FM und ist damit nicht als fertiger 85-Hz-RTTY-Decoder belegt. fldigi kann 50 Baud und 85 Hz, braucht aber X11. multimon-ng wird nicht verwendet. Kein unsignierter Download, keine stille Installation.
4. Danach Speichern der Gruppen in einer neuen Ablage, ohne die bestehende Datenbank zu löschen und ohne Alarm oder Mesh.
5. Danach die laufende Anzeige der Gruppen, weiterhin ohne Warnstufe.

## Tests

- pinneberg_rolle.selftest: Frequenz, kein 1900-Hz-Zusatz, kein Bias-Tee, Preflight bei fehlender, doppelter, falscher und Airspy-Rolle, Replay leer, veraltet, untauglich und maritim, alles ohne Alarm.
- selftest_sdrstick3e: ohne Datei bleibt APRS auf Stick 3 und 433 auf Stick 2. Mit Datei wird Stick 3 still, Stick 2 übernimmt APRS nicht, auch wenn Stick 3 als fehlend gilt. Nach Löschen der Datei kehrt APRS zurück. Airspy-Gain und die übrigen Fälle des bestehenden Tests bleiben grün.
- Import von dashboard.py: pinnebergRolle, funkFlach und audioKern melden ok.
- Guard und Mutationstest im Apply: 10/10, Variante trim.
- Sandbox Port 5093: Trockenlauf schreibt nicht. Normaler Lauf auf der Kürzung, ein Dashboard-Neustart, prepper-sdr unverändert, Zielhashes, JSON ohne Seriennummer und mit empfang false. Zweiter Lauf ohne weiteren Neustart. Ungekürzte Basis bleibt ungekürzt. Fremde lage_pages.py und commit63-Dashboard stoppen vor jeder Änderung. Sperre 21:51 stoppt vor dem Ersetzen. Trockenlauf um 12:50 schreibt nicht. Fehlerseite nach dem Neustart stellt commit64 wieder her und entfernt die neuen Dateien.
- 14 Seiten und 16 APIs wie vorher. Die Bereitschaft verlangt die echte Funkseite und /api/pinneberg, nicht den Startbildschirm.

Ein echtes Spektrum und ein echter Wettertext wurden nicht erzeugt. Auf dem Pi wurde nichts ausgeführt.

## Offen, keine weiteren Schritte

Der nächste sinnvolle Schritt wäre ein ausdrücklich freigegebener Neustart nur von prepper-sdr, damit die Reservierung im laufenden Prozess ankommt. Decoder, Spektrum und CSP/ntfy sind nicht Bestandteil dieser Lieferung.
