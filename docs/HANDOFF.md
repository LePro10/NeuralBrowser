# Übergabe – 13.11.2026

## Auftrag
NeuralBrowser bauen: cleaner, sehr leichter Open-Source-Browser (MPL-2.0), KI als
abschaltbare Schicht später. Umsetzung mit Subagents: Opus für Schweres, Sonnet sonst.
Plan: `docs/PLAN.md`, Entscheidung Phase 0: `docs/ENTSCHEIDUNG.md`. Repo öffentlich:
https://github.com/LePro10/NeuralBrowser

## Stand (alles committet und gepusht, main = `573ee44`)
- Rust-Kern `core/neural-core`: Store (Verlauf, Lesezeichen, Sitzung, Einstellungen,
  Vorschläge), Eingabe-Auflösung, `shield` (Filterlisten → WebKit-Regel-JSON). 22 Tests grün.
- macOS-App `apps/apple` (Swift/AppKit, SwiftPM, kein Xcode): Tabs in Seitenleiste,
  Befehlsleiste, Sitzung, Suche in Seite, Downloads, privates Fenster, schlafende Tabs,
  Rust-Store angebunden. App 4,3 MB.
- Erweiterungen über WKWebExtension plus Übersetzer (`Sources/ExtensionTranslator`),
  sicherer Installer, Verwaltungsansicht. Selbsttest 118/118. Mit Übersetzer laufen laut
  Agent 6 von 10 Erweiterungen, Bitwarden teilweise (`docs/ERWEITERUNGS-TEST.md` Abschnitt 9).
- Bedrohungsmodell `docs/SECURITY.md`, öffentliche Liste `docs/ERWEITERUNGEN.md`.

## Nächste Schritte
1. `shield` in die App einbinden: Listen laden, `convertFilterLists`, mit
   `WKContentRuleListStore` kompilieren, an WebViews hängen, Schalter pro Website
   (`appendSiteExceptions`). Im echten Fenster prüfen, dass geblockt wird.
2. Rest Phase 1: Oberfläche für Lesezeichen, Verlauf, Einstellungen (Suchmaschine),
   RAM-Anzeige pro Tab, heller Modus ansehen.
3. Nutzer testet Bitwarden mit Vaultwarden-Login (Menü "Install Extension…", Paket aus
   den GitHub-Releases von `bitwarden/clients`): entsperren, ausfüllen, speichern.
4. Erweiterungs-Tests mit entsperrtem Bildschirm wiederholen (siehe Risiken).
5. Lokaler Passwort-Speicher über den Schlüsselbund (Plan Phase 2), danach Sync (Phase 3).
6. Skill `codemap` laufen lassen (viele neue Dateien).

## Offene Fehler / Risiken
- Bei gesperrtem Bildschirm antworten Erweiterungs-Hintergründe nach wenigen Sekunden
  nicht mehr (auch ohne Übersetzer). Ursache unklar.
- Ungeprüft: 15-Minuten-Timer der schlafenden Tabs, Wachhalten bei Ton/Video,
  Blockverhalten der Regel-Listen im echten WebView, Verhalten bei kaputter Datenbank,
  Verwaltungsansicht von Hand durchgeklickt.
- Stylus, Return YouTube Dislike und Userscript-Manager unter Manifest V3 laufen nicht.
- Linker-Warnungen sind pauschal stumm (`-Xlinker -w` in `apps/apple/Package.swift`).
- Verlaufseinträge haben noch keine Sync-Kennung (nur Lesezeichen und Ordner).

## Wichtige Stellen
- `apps/apple/README.md` – Bauen (`scripts/bundle.sh`), Starten (`scripts/run.sh`), alle
  Selbsttests (`--smoke-test`, `--ext-script`, `--extension-report`, `translator-selftest`).
- `core/README.md` – Kern-API, `core/build-apple.sh` erzeugt die Swift-Bindings.
- Selbsttests immer mit temporärem Profil (`--profile-dir`), nie das echte Profil.

## Entscheidungen
- WebKit bleibt, Erweiterungen werden beim Installieren übersetzt (Nutzer, 13.11.2026).
- Git-Identität lokal: GitHub-noreply-Adresse. Parallel-Agents über `git worktree` unter
  `.worktrees/` (automatische Worktree-Isolation funktioniert in dieser Umgebung nicht).
- Es fehlen Xcode und rustup: nötig für iOS, Android und Notarisieren.
