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
1. ~~`shield` in die App einbinden~~ erledigt 13.11.2026:
   `Sources/NeuralBrowser/Shield/Shield.swift`, Menü Ansicht → „Block Ads and Trackers“ (global
   und pro Website), Test `apps/apple/scripts/shield-test.sh` 5/5 grün, echte Listen 130.584
   Regeln in 2,6 s. Schalter pro Website hängt die Listen pro Tab ab statt `appendSiteExceptions`
   (sonst Neukompilieren, Sekunden pro Klick). Details: `apps/apple/README.md` „Content blocking“.
2. Rest Phase 1: Oberfläche für Lesezeichen, Verlauf, Einstellungen (Suchmaschine),
   RAM-Anzeige pro Tab, heller Modus ansehen.
3. **Vaultwarden: erste echte Anmeldung mit dem Nutzer testen.** Gebaut 13.11.2026: Kern
   `core/neural-core/src/vault/` (ohne Netz, Krypto aus rbw), Oberfläche
   `apps/apple/Sources/NeuralBrowser/Vault/` (File ▸ Passwords… ⇧⌘P, Edit ▸ Fill Login ⌘\,
   Edit ▸ Save Login…). Tests: `cargo test` 44/44, `scripts/vault-fill-test.sh` 25/25.
   **Nie gegen einen echten Server gelaufen.** Unsichere Protokoll-Details, falls die
   Anmeldung scheitert (Fehlertext im Fenster und Log-Zeile „NeuralBrowser vault:“):
   `Device-Type 7` mit `client_id=cli`, `Bitwarden-Client-Version 2024.12.0`, Inhalt der
   Anfrage für den E-Mail-Code, Fehlertexte bei falschem Zweitfaktor. Von Hand ungeprüft:
   Fenster in hell/dunkel, Auswahl bei mehreren Treffern, Speichern-Fenster, Sperren bei
   Bildschirmsperre. Danach: angemeldet bleiben über Neustart (Refresh-Token im
   Schlüsselbund, verschlüsselter Tresor-Stand auf Platte), Einträge ändern, Host-Spalte.
   `cargo audit`/`cargo deny` sind nicht installiert und liefen nie (SECURITY.md Regel 9).
   Popup-Fehler der Erweiterungs-Symbole: Absicherung eingebaut (siehe Risiken), der Nutzer
   muss im echten Gebrauch bestätigen, ob es jetzt zuverlässig öffnet.
4. Erweiterungs-Messungen aus ERWEITERUNGS-TEST.md Abschnitt 9, die am Nachmittag scheiterten,
   mit dem ITP-Fix wiederholen (siehe Risiken).
5. Lokaler Passwort-Speicher über den Schlüsselbund (Plan Phase 2), danach Sync (Phase 3).
6. Skill `codemap` laufen lassen (viele neue Dateien).

## Offene Fehler / Risiken
- **Popup öffnet oft nicht – eine Ursache gefunden und abgesichert (13.11.2026), im echten
  Gebrauch noch nicht bestätigt:** WebKit zeigt ein Popup nur, wenn dessen Seite nach dem Klick
  fertig lädt, und ignoriert weitere Klicks, solange es ein Popup für „offen oder unterwegs“
  hält. Lädt die Popup-Seite einmal nicht fertig (oder war sie schon geladen), bleibt dieser
  Zustand hängen; `closePopup()` setzt ihn im WebKit des Systems nicht zurück. Nachgestellt mit
  `--ext-script` (`popupState` vor `clickAction`). Abhilfe in `ExtensionManager.actionClicked`:
  nach 1,5 s ohne Popup wird die Popup-Seite neu geladen (WebKit zeigt sie dann selbst), nach
  weiteren 3 s zeigen wir sie direkt; jeder Fall steht im Log („popup not presented“). Dazu
  Klickfläche 28×24 statt 16×16 pt, Fehler an WebKit, wenn kein Fenster da ist, und ein Klick
  aufs Symbol bei offenem Popup schließt es nur noch (letzteres nicht mit echter Maus geprüft).
  Warum die Popup-Seite beim Nutzer nicht fertig lädt, ist weiter offen.
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
  Verhalten bei kaputter Datenbank, Shield-Menüschalter von Hand geklickt (nur per
  Startoption getestet), Shield-Aktualisierung nach 4 Tagen, Shield ohne Netz beim ersten Start,
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

## rbw als Bibliothek (geprüft 13.11.2026, Quelltext 1.15.0, Commit 77464d4)
- rbw hat eine Bibliotheks-Schnittstelle (`src/lib.rs`, alle Module `pub`). Als Abhängigkeit
  taugt das Crate trotzdem nicht: es zieht `axum`, `clap`, `daemonize`, `ssh-agent-lib`,
  `tokio` (full), `arboard` und Unix-only-Crates mit; `actions.rs` liest fest die
  Konfigurationsdatei unter `~/.config/rbw`.
- Brauchbar und klein: `cipherstring.rs` (315 Zeilen), `identity.rs` (94), `locked.rs` (165),
  `base64.rs` – reine RustCrypto-Aufrufe, kein Netz, keine Konfiguration. `api.rs` (1768) hat
  die Anfrage-/Antwort-Formate (prelogin, login mit Zwei-Faktor, sync, add, edit, Token
  erneuern); `Client::new(base_url, identity_url, ui_url, cert)` nimmt die Adressen direkt,
  hängt aber an `reqwest`, `tokio` und `axum` (SSO-Rückruf).
- Umgesetzt (Nutzer-Freigabe 13.11.2026): Krypto-Module unverändert übernommen, der Kern
  baut Anfragen und liest Antworten, die Hülle sendet sie mit URLSession.

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
**Entschieden (Nutzer, 13.11.2026): Weg (a), rbw-Code (MIT), Lizenz bleibt MPL-2.0.**
Ursprüngliche Frage: (a) auf rbw-Code (MIT) aufbauen und die
Kryptografie-Bausteine der RustCrypto-Crates nutzen – Empfehlung, Lizenz bleibt MPL-2.0;
(b) offizielles SDK unter GPL-3.0, dann wird die App faktisch GPL-3.0. In beiden Fällen
vorher prüfen: rbw-Quelltext als Bibliothek nutzbar?, Test gegen den Vaultwarden-Server
des Nutzers, Protokoll gegen Vaultwarden `src/api/identity.rs` abgleichen.
Quellen: github.com/bitwarden/sdk-internal (LICENSE, LICENSE_SDK.txt), github.com/doy/rbw,
bitwarden.com/help/bitwarden-security-white-paper, bitwarden.com/help/new-device-verification
