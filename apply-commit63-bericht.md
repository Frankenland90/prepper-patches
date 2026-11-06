# commit63 usvNamen — Prüfbericht

Nicht veröffentlicht. Nicht gemergt. Nicht auf kaeswasser-lage-monitor oder main gepusht. Kein Pi-Zugriff.

## Artefakt

- Datei: /opt/cursor/artifacts/apply-commit63.sh
- sha256: 3ba47f58312973d2212f8c63bf471227b41b53913a4163c1dac0a0530a51f8d4
- Größe: 2676712 Bytes
- bash -n: ok

## Review

- Branch: cursor/usv-spitzboden-eg-d32b
- Commit: b4ec9275d39bf01f952eeff9f62ba92e86b837bc
- PR: https://github.com/Frankenland90/kaeswasser-lage-monitor/pull/2
- Basis: kaeswasser-lage-monitor a86c923116a43b0e942dbb99721db8320864886f
- Deployment-Branch danach unverändert a86c923, main unverändert 0a6c782

## Zielhashes

| Datei | sha256 | sha16 |
|---|---|---|
| ups_manager.py | b2e491e36a9a1861de4c609f80a613f9b824e4f6f52319c50e5c5a87252ddcf8 | b2e491e36a9a1861 |
| dashboard.py | 8a055ad3ed0619f681e2575c5ad588c3a28330eba1c00daab46d1cde46e28908 | 8a055ad3ed0619f6 |
| lage_pages.py ungekürzt | d268d324f4fd55a53cb7ee1919e3fb399e2c4ca0a7733780c9bf977b0fee2fca | d268d324f4fd55a5 |
| lage_pages.py gekürzt | 6b10e3bae7118d9519760b492220e88a5caf2e9dc99e9ed8db096eb911d0e778 | 6b10e3bae7118d95 |
| prepper_docs.py | 8f9983737e5217a4dbaecbc8764d6889cff10f0a82a41fe7b97e1bf9671e3751 | 8f9983737e5217a4 |

Basis lage_pages.py: ungekürzt 536780ba4b89a69a34183d20a802251ec5f8dbc4f19b7a6a8d95c516e2e13a9f, gekürzt 5185cfefaf5dbc1c30ae6349278f1fe43832c4fed92fe7619484ae2ac7ec7e74. Andere Dateien nur der commit62-Stand.

## Verhalten

- Lokale USV heißt USV SPITZBODEN. Messung weiter nur 127.0.0.1:3493, nur LIST.
- USV EG: nicht verbunden, Host 192.168.178.3, Pi-hole, keine Messung, keine Steuerung, keine Zahlen.
- SoH nur aus gelernter Laufzeit. Ohne Basis: unbekannt. Während der 14 Tage: lernt. Ladezustand allein ergibt kein SoH. Ladung über 100 % oder Laufzeit kleiner oder gleich 0 zählt nicht als SoH-Probe.
- Einbau 05.2026. Wechsel nicht festgelegt. Kein Austauschdatum, keine Lebensdauer.
- Abschaltung 20 % oder 5 min und USVA_LOW_S 300 sowie OB_CONFIRM_S 20 unverändert.
- Die drei Zeilen Profil und Szenariohinweis werden nicht wieder eingefügt, wenn die gekürzte Basis vorliegt.

## Tests

- ups_manager.selftest: ok
- py_compile der vier Dateien: ok
- prepper_docs.py --check --no-live: Trockenlauf, nichts geschrieben
- Guard: full und trim ok
- Mutationen: 10/10, 0 übersehen
- Trockenlauf ungekürzt: Baum unverändert
- Normal: zwei Startbildschirme, dann Seite mit USV SPITZBODEN, USV EG und „keine USV-Daten“; Zielhash ungekürzt; ein Neustart nur prepper-dashboard
- Zweiter Lauf: keine Änderung, kein zweiter Neustart
- Gekürzte Basis: Zielhash 6b10e3bae7118d95, scenario_note und profile_text bleiben weg, Heizsaison und Tiefststand bleiben
- Unbekannte lage_pages.py: STOP vor jeder Änderung
- Mischstand: STOP
- Falsche Seite nach Neustart: Rollback auf commit62
- Sperre 12:50: Hinweis, Trockenlauf schreibt nicht

In dieser Umgebung sind System-Python und venv derselbe Interpreter, weil die Sim-Kopie keine venv hat. Auf dem Pi prüft das Skript beide.
