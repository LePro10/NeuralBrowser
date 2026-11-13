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
3. **Vaultwarden fest einbauen** (Nutzer-Entscheidung 13.11.2026, hat Vorrang vor der
   Bitwarden-Erweiterung): zuerst `docs/SECURITY.md` um den Baustein ergänzen, dann
   Bibliothek wählen (Recherche unten), Kern-Modul in Rust, Oberfläche in Swift
   (anmelden, entsperren, ausfüllen, speichern). Echte Anmeldung testet der Nutzer mit.
   Unabhängig davon: Klick auf ein Erweiterungs-Symbol öffnet das Popup oft nicht
   (vermutlich unsere App, `UI/SidebarView.swift` / Popover-Code) – beheben und testen.
4. Erweiterungs-Messungen aus ERWEITERUNGS-TEST.md Abschnitt 9, die am Nachmittag scheiterten,
   mit dem ITP-Fix wiederholen (siehe Risiken).
5. Lokaler Passwort-Speicher über den Schlüsselbund (Plan Phase 2), danach Sync (Phase 3).
6. Skill `codemap` laufen lassen (viele neue Dateien).

## Offene Fehler / Risiken
- **Bitwarden im echten Gebrauch unzuverlässig (Nutzer, 13.11.2026, nach dem ITP-Fix):**
  Klick auf das Symbol öffnet das Popup oft nicht (einmal bei rund 10 Klicks); nach Eingabe
  des Master-Passworts bleibt die Anmeldung hängen, obwohl die Login-Mail des Servers ankam;
  zeitweise weiter nur Ladekreis. Vermutlich drei getrennte Fehler, keiner ist belegt. Echte
  Anmeldung wurde nie automatisch getestet. Im System-Log war dazu nichts zu finden.
- Erweiterungs-Hintergründe, die nach wenigen Sekunden nicht mehr antworten (Bitwarden-Popup
  mit Ladekreis): Ursache war WebKits Tracking-Schutz (ITP), nicht der gesperrte Bildschirm.
  Behoben, indem die Erweiterungs-Herkunft als „vom Nutzer besucht“ vermerkt wird (WebKit-SPI
  `_logUserInteraction:completionHandler:`; fehlt sie künftig, kehrt der Fehler zurück – Log-Zeile
  „SPI _logUserInteraction missing“). Ein eigener Datenspeicher für Erweiterungsseiten ist keine
  Alternative: dann stellt WebKit `runtime.sendMessage` nicht mehr an den Service Worker zu
  (gemessen, Smoke-Test „no-reply“). Test: `apps/apple/scripts/ext-normal-test.sh`. Offen: Die
  Basis-URL der Erweiterungen ist pro Start zufällig (Web-Speicher der Erweiterungsseiten überlebt
  keinen Neustart, `chrome.storage` schon; jede Start-URL landet als eigene Domain in der ITP-Datenbank).
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

## Recherche: Bibliothek für die Vaultwarden-Anbindung (13.11.2026, Haiku-Recherche)
Es gibt keine fertige, sauber lizenzierte Bibliothek. Kandidaten:
- **Offizielles Bitwarden-SDK** (`bitwarden-core`, `bitwarden-crypto`, 4.0.0): Lizenz
  "GPL-3.0 oder Bitwarden SDK License". Die SDK-Lizenz schließt fremde Software aus. Mit
  der GPL-Option würde die verteilte App insgesamt GPL-3.0 (Lesart des Rechercheurs, keine
  Rechtsberatung). Crates tragen den Hinweis "Internal crate … Do not use", API instabil.
- **rbw** (doy, MIT, 1.15.0 vom 31.12.2025): passt zur Lizenz, ist aber ein
  Kommandozeilen-Programm ohne dokumentierte Bibliotheks-Schnittstelle; seit Dezember 2025
  kein Commit ("feature-complete"); Zwei-Faktor per E-Mail, App und Yubico OTP, keine
  Passkeys; Vaultwarden-Betrieb und Sicherheitsprüfung unbelegt.
- `bw serve` (offizielles CLI): braucht Node, lokale Schnittstelle ohne Anmeldung,
  Lizenz des Pakets unklar. Triwarden (GPL-3, Swift, 0.x) nur als Referenz.
**Offene Entscheidung für den Nutzer:** (a) auf rbw-Code (MIT) aufbauen und die
Kryptografie-Bausteine der RustCrypto-Crates nutzen – Empfehlung, Lizenz bleibt MPL-2.0;
(b) offizielles SDK unter GPL-3.0, dann wird die App faktisch GPL-3.0. In beiden Fällen
vorher prüfen: rbw-Quelltext als Bibliothek nutzbar?, Test gegen den Vaultwarden-Server
des Nutzers, Protokoll gegen Vaultwarden `src/api/identity.rs` abgleichen.
Quellen: github.com/bitwarden/sdk-internal (LICENSE, LICENSE_SDK.txt), github.com/doy/rbw,
bitwarden.com/help/bitwarden-security-white-paper, bitwarden.com/help/new-device-verification
