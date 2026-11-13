# NeuralBrowser – Entscheidung nach Phase 0

Stand: 13.11.2026. Grundlage: Prototyp auf macOS 27 (arm64), Messungen der Agenten und
eigene Nachprüfung. Einzelheiten zu den Erweiterungen: `docs/ERWEITERUNGS-TEST.md`.

## Entscheidung

**WebKit bleibt die Engine. Erweiterungen werden beim Installieren automatisch
umgeschrieben ("Übersetzer"), damit bekannte WebKit-Lücken umgangen werden.**
Entschieden vom Projektinhaber am 13.11.2026, nachdem die Regel aus dem Plan
(mindestens 12 von 15 Erweiterungen inklusive Bitwarden) verfehlt wurde.

Was das bedeutet:
- Es werden nie alle Chrome-Erweiterungen laufen. Das Projekt führt eine öffentliche
  Liste getesteter Erweiterungen mit ehrlichem Status.
- Userscripts, eigene Stile und Werbeblocker werden fest eingebaut, weil die passenden
  Erweiterungen auf WebKit grundsätzlich nicht gehen (fehlende Schnittstellen
  `userScripts` und blockierendes `webRequest`).
- Bitwarden mit Vaultwarden ist Testfall Nummer eins für den Übersetzer. Der Test mit
  echter Anmeldung (entsperren, ausfüllen, speichern) steht noch aus und braucht den
  Projektinhaber.
- Die Hülle bleibt nativ in Swift (macOS und iOS), der Kern in Rust.

## Messwerte

| Messung | Wert | Quelle |
|---|---|---|
| Größe der App | 2,3 MB | selbst gemessen |
| Fenster sichtbar nach Start | etwa 0,2–0,3 s | selbst gemessen, mehrere Läufe |
| RAM der App ohne Webinhalt | etwa 24 MB (Footprint) | Agent |
| RAM mit 3 Tabs (Wikipedia, GitHub, Hacker News) | App 33 MB, Webinhalte 197 MB, Grafik und Netzwerk 31 MB | Agent |
| Vorschläge bei 100.000 Verlaufseinträgen | 1–6 ms | Agent, Benchmark-Test |
| Erweiterungen unverändert lauffähig | 4 von 10 getesteten | Agent, `docs/ERWEITERUNGS-TEST.md` |
| Entwicklerkonto oder Sonderfreigabe für Erweiterungen | nicht nötig | Agent, mit Test-Erweiterung belegt |

Zielwerte aus dem Plan (App unter 25 MB, Fenster unter 0,3 s, Hülle unter 80 MB RAM)
sind eingehalten.

## Nicht gemessen

- Vergleich des RAM-Verbrauchs mit Chrome und Safari bei gleichen Seiten.
- 20 Alltagsseiten und Agenten-Aktionen (kommt mit der KI-Schicht).
- Gegenprobe mit reiner Rust-Hülle (`wry`): gestrichen, weil Erweiterungen und iOS die
  native Hülle ohnehin verlangen.
- Apple-Freigabe für Passkeys in eigenen Browsern.
