# NeuralBrowser – Plan

Stand: 13.11.2026, Fassung 2 (nach deinen Antworten und der Nachrecherche zu Erweiterungen).
Faktencheck des Ausgangstextes, Marktlage und Quellen: `docs/FAKTENCHECK.md`.
Kennzeichnung: **[belegt]** = mit Quelle geprüft, **[Einschätzung]** = mein Urteil,
**[offen]** = nicht geprüft, wird in Phase 0 durch Ausprobieren geklärt.

---

## 1. Kurzfassung

- **Was es wird:** ein sauberer, sehr schneller Open-Source-Browser der nächsten
  Generation. KI ist eine abnehmbare Schicht obendrauf, nicht der Kern.
- **Für wen:** die Open-Source-Community und Entwickler, die sich über RAM-Verbrauch und
  halbgare KI-Funktionen in heutigen Browsern ärgern.
- **Ziel:** ein bekanntes Open-Source-Projekt mit einigen tausend echten Nutzern, kein
  Chrome-Ersatz für alle.
- **Technik:** Rust-Kern für alles Eigene, dünne native Hülle pro Plattform,
  System-Engine (WebKit zuerst). macOS zuerst, dann iOS, Linux/Windows, Android.
- **Der Knackpunkt:** "leicht" und "alle Chrome-Erweiterungen" widersprechen sich
  teilweise. Phase 0 misst, wie viele der wichtigsten Erweiterungen auf WebKit wirklich
  laufen. Danach entscheidest du mit Zahlen.
- **Sicherheit:** kein selbst gebauter Krypto-Code, Bedrohungsmodell vor dem ersten
  Feature, Agent immer in eigenem Profil.

---

## 2. Deine Vorgaben (aus den Rückfragen)

| Thema | Vorgabe |
|---|---|
| Ziel | Bekanntes, cooles Open-Source-Projekt |
| Charakter | Zuerst ein cleaner Next-Generation-Browser, KI obendrauf |
| Leistung | Top-performant, wenig RAM |
| Erweiterungen | Die gängigen Chrome-Erweiterungen sollen laufen ("übersetzt") |
| Passwörter | Eigene Passwort-Erweiterung installierbar (z. B. Bitwarden mit Vaultwarden); wer keine hat, speichert lokal im Browser |
| Sync | Eigener Server zum Selbst-Hosten, Alternative: nur lokal |
| KI | Agenten-Steuerung (MCP), semantischer Verlauf, Seite zusammenfassen und befragen, alles abschaltbar, effizient und zuverlässig |
| Plattformen | Desktop, später auch Android und iOS |
| Grundsatz | Alles sicher und durchdacht |

---

## 3. Die ehrliche Kernfrage: leicht oder alle Erweiterungen?

| Weg | Erweiterungen | Gewicht | Mobil | Pflege |
|---|---|---|---|---|
| **A: WebKit über die System-Engine** | Über Apples Schnittstelle `WKWebExtension` (ab macOS 15.4 und iOS 18.4 [belegt]). Lädt Chrome-artige Erweiterungen, aber nur mit den Funktionen, die WebKit kennt. Welche gängigen Erweiterungen laufen, ist [offen]. | Sehr leicht | iOS ja | Engine-Updates kommen vom System |
| **B: Chromium-Fork** | Alle Chrome-Erweiterungen | Schwer, RAM wie Chrome | iOS nein | Sehr hoch, Sicherheits-Updates alle paar Wochen selbst |
| **C: Firefox-Fork** | Alle Firefox-Erweiterungen (die meisten bekannten gibt es dort), auch auf Android | Mittel | iOS nein | Hoch |

- "Alle Chrome-Erweiterungen" garantiert nur Weg B. Der ist aber genau das, worüber sich
  die Zielgruppe ärgert, und für eine Person kaum zu pflegen. [Einschätzung]
- Der Browser Orion (Kagi) zeigt, dass Chrome- und Firefox-Erweiterungen auf WebKit
  möglich sind, wirbt aber selbst nur mit einer kuratierten Auswahl. [belegt]
- **Vorschlag:** Weg A, und Phase 0 prüft ihn hart: Die 15 wichtigsten Erweiterungen
  werden in einem Prototyp geladen und getestet (Liste in Abschnitt 8).
  - Laufen mindestens 12 von 15 inklusive Bitwarden: Weg A ist bestätigt.
  - Laufen weniger: Du entscheidest mit den Zahlen, ob Leichtigkeit oder Erweiterungen
    Vorrang hat. Der Rust-Kern bleibt in beiden Fällen derselbe.
- Unabhängig davon ist das Wichtigste fest eingebaut, damit weniger Erweiterungen nötig
  sind: Werbeblocker, Lesemodus, Dunkelmodus, Userscripts, lokaler Passwort-Speicher.

---

## 4. Architektur

### 4.1 Rust-Kern plus native Hüllen

```
neuralbrowser/
  core/                 Rust, auf allen Plattformen gleich
    store/              Tabs, Sitzungen, Verlauf, Lesezeichen, Einstellungen (SQLite)
    sync/               Ende-zu-Ende-verschlüsselter Abgleich
    shield/             Werbeblocker (adblock-rust), Tracker-Schutz
    secrets/            Zugriff auf System-Schlüsselbund, lokaler Passwort-Speicher
    agent/              Seiten-Abbild für KI, Aktionen, Rechte, Protokoll
    mcp/                MCP-Server (Browser steuern) und MCP-Client (Werkzeuge)
    ai/                 Modell-Anbieter, Zusammenfassen, Einbettungen
    ffi/                Brücke zu den Hüllen (UniFFI)
  apps/
    apple/              Swift: macOS und iOS, WKWebView, Erweiterungen
    desktop/            Rust-Hülle für Windows und Linux (später)
    android/            Kotlin (später)
  server/sync/          Sync-Server zum Selbst-Hosten (ein Rust-Programm)
```

**Warum native Hüllen statt einer Rust-Oberfläche für alles [Einschätzung]:**
- Apples Erweiterungs-Schnittstelle hängt an der nativen WebView-Konfiguration. Ob die
  Rust-Bibliothek `wry` daran herankommt, ist unbelegt; auf iOS und Android kann `wry`
  ohnehin keine eingebetteten WebViews als Tabs [belegt].
- Eine Swift-Hülle deckt macOS und iOS mit weitgehend gleichem Code ab und fühlt sich am
  schnellsten und saubersten an.
- Alles, was das Projekt ausmacht, liegt im Rust-Kern und wird einmal geschrieben. So
  arbeiten auch Firefox und Bitwarden auf Mobilgeräten.
- Preis: Die Oberfläche wird pro Plattform-Familie gebaut. Phase 0 prüft als Gegenprobe,
  ob eine reine Rust-Hülle an die WebKit-Konfiguration herankommt.

### 4.2 Leistung als Merkmal

- Tabs schlafen automatisch ein, wenn sie nicht genutzt werden; Wiederherstellung erst
  beim Anklicken.
- RAM-Anzeige pro Tab und gesamt, damit der Unterschied sichtbar ist.
- Werbeblocker im Kern senkt RAM und CPU spürbar.
- Keine Hintergrund-Dienste, keine Telemetrie.
- Feste Obergrenzen, die automatisch bei jedem Beitrag geprüft werden. Zielwerte, in
  Phase 0 zu bestätigen: App unter 25 MB, Fenster sichtbar in unter 0,3 s, Hülle ohne
  Webinhalt unter 80 MB RAM.

### 4.3 Erweiterungen in drei Stufen

1. **Eingebaut:** Werbeblocker, Lesemodus, Dunkelmodus, Userscripts und eigene Stile.
2. **Browser-Erweiterungen:** über `WKWebExtension` auf macOS und iOS. Installation aus
   entpackten Paketen; ob direkt aus dem Chrome Web Store geladen werden darf, ist
   rechtlich und technisch [offen]. Windows (WebView2) lädt Erweiterungen nur aus
   lokalen Ordnern [belegt], Android nur mit GeckoView und von Mozilla signiert [belegt],
   Linux (WebKitGTK) nur lückenhaft [belegt].
3. **Neue Art:** MCP-Server und kleine Plugins mit festen Rechten, die auch ein Agent
   schreiben kann. Installiert wird nie automatisch: Ein Mensch sieht vorher Code und
   Rechte. Für Userscripts gelten dieselben Regeln wie für Erweiterungen.

**Sicherheit bei Erweiterungen:** Rechte werden vor der Installation klar angezeigt, bei
Updates nur die neu verlangten Rechte. Im Agenten-Profil und in privaten Fenstern sind
Erweiterungen standardmäßig aus.

### 4.4 Passwörter

- **Mit Erweiterung:** Bitwarden (auch mit Vaultwarden-Server), 1Password und andere
  laufen als normale Erweiterung. Das ist Testfall Nummer eins in Phase 0.
- **Ohne Erweiterung:** eingebauter lokaler Speicher. Die Passwörter liegen im
  System-Schlüsselbund (macOS Schlüsselbund, Windows Anmeldeinformationen, Linux Secret
  Service), entsperrt per Touch ID oder Gerätepasswort. Der Browser erfindet keine
  eigene Verschlüsselung und legt keine eigene Tresor-Datei an.
- Lokale Passwörter werden nicht über den Sync abgeglichen. Wer Abgleich will, nutzt
  Bitwarden oder Vaultwarden. Das hält das Risiko klein.
- "100 % sicher" gibt es nicht. Das Ziel ist: nichts Eigenes an der gefährlichsten Stelle.
- **Passkeys:** Für eigene Browser auf macOS braucht es eine Freigabe von Apple, die
  Einzelpersonen laut einem Entwicklerbericht nicht bekommen [eine Quelle, offen].
  Ausweg: Bitwarden kann Passkeys selbst verwalten.

### 4.5 Sync

- Abgeglichen werden Lesezeichen, offene Tabs, Einstellungen, auf Wunsch der Verlauf.
- Standard ist **kein Sync** (alles lokal). Wer will, trägt die Adresse seines eigenen
  Servers ein.
- **Sync-Server:** ein einzelnes Rust-Programm plus Docker-Abbild, so einfach wie
  Vaultwarden. Er speichert nur verschlüsselte Pakete und kennt keine Inhalte.
- Verschlüsselung auf dem Gerät mit fertigen, geprüften Bibliotheken. Kein Konto und
  kein Passwort beim Server.
- Koppeln: Der QR-Code startet einen kurzlebigen Koppel-Vorgang mit Vergleichscode auf
  beiden Geräten. Er überträgt nicht den Dauerschlüssel. Jedes Gerät hat ein eigenes
  Schlüsselpaar.
- Wird ein Gerät entfernt, wechselt der Schlüssel. Der Server kann keine alten Stände
  unbemerkt zurückspielen.
- Sicherheits-Einstellungen (Agenten-Rechte, MCP, Erweiterungen) werden nicht
  synchronisiert.
- Konflikte: pro Eintrag gewinnt die letzte Änderung, Löschungen werden gemerkt.
- Dazu Export und Import als Datei (auch Lesezeichen aus Chrome, Firefox, Safari).

### 4.6 KI als abnehmbare Schicht

Der Browser läuft vollständig ohne KI. Sie ist standardmäßig aus und mit einem Schalter
ganz entfernbar.

- **Agenten-Steuerung über MCP:** Werkzeuge wie Tabs auflisten, Seite öffnen, lesen,
  klicken, tippen, Verlauf durchsuchen. Nur lokal, ohne offenen Netzwerk-Port, mit
  einem eigenen Zugangs-Token pro Programm, das den Browser steuern darf.
- **Sparsames Seiten-Abbild:** statt rohem HTML ein gekürzter Baum aus sichtbaren,
  bedienbaren Elementen. Ziel: wenige tausend Token pro Seite. Das macht Agenten
  schneller, billiger und zuverlässiger.
- **Rechte pro Website:** "nie", "nur lesen", "bedienen mit Nachfrage", "frei". Bank,
  Mail und Zahlungsseiten stehen standardmäßig auf "nie", unbekannte Seiten auf
  "nur lesen".
- **Kein stiller Datenfluss:** Was der Agent auf einer Website gelesen hat, geht nur mit
  Nachfrage an eine andere Website.
- **Eigenes Agenten-Profil** ohne deine Logins. Zugriff auf eine eingeloggte Seite gibst
  du einzeln frei.
- **Bestätigung bei Folgen:** Absenden, Kaufen, Nachrichten schicken, Herunterladen.
- **Protokoll und Stopp-Knopf** für alles, was ein Agent tut.
- **Seite zusammenfassen und befragen**, **semantischer Verlauf**: lokal, mit lokalem
  Modell (z. B. über Ollama) oder eigenem API-Schlüssel im System-Schlüsselbund.

Prompt Injection ist nicht lösbar, nur begrenzbar [belegt, siehe Faktencheck]. Das
Rechte-Modell begrenzt den Schaden.

---

## 5. Sicherheit als eigener Baustein

- `docs/SECURITY.md` entsteht in Phase 0, vor dem ersten Feature: Was schützen wir, vor
  wem, was ausdrücklich nicht.
- Keine selbst gebaute Kryptografie. Geheimnisse nur im System-Schlüsselbund.
- Engine-Sicherheit kommt vom Betriebssystem. Das ist der Hauptgrund für die
  System-Engine: Eine Einzelperson kann Engine-Lücken nicht im Wochentakt selbst flicken.
- Signierte Updates, automatische Prüfung aller Abhängigkeiten bei jedem Beitrag.
- Web-Inhalt, Erweiterungen und Agent sind drei getrennte Vertrauensstufen.
- Meldeweg für Sicherheitslücken ab der ersten öffentlichen Version.
- Wenn das Projekt wächst: externe Prüfung von Sync und Passwort-Speicher.

---

## 6. Fahrplan

Zeitangaben sind grobe Schätzungen für konzentrierte Arbeit einer Person mit KI-Agenten.

### Phase 0 – Messen und entscheiden (2 Wochen)
- Prototyp A: Swift-Hülle mit WKWebView, drei Tabs, Rust-Kern über UniFFI angebunden,
  `WKWebExtension` lädt Erweiterungen.
- Gegenprobe B: reine Rust-Hülle (`tao` + `wry`), prüfen ob die WebKit-Konfiguration
  für Erweiterungen erreichbar ist.
- Erweiterungs-Test mit 15 Erweiterungen (Abschnitt 8).
- Messen: App-Größe, RAM mit 10 Tabs gegen Chrome und Safari, Startzeit, 20 Alltagsseiten,
  10 Agenten-Aktionen (klicken und tippen, auch in React-Formularen).
- Klären: Apple-Freigaben (Passkeys, Standard-Browser), Laden aus dem Chrome Web Store,
  Lizenz der Bitwarden-Erweiterung, aktuelle Version des MCP-Rust-SDK.
- Bedrohungsmodell schreiben.
- **Fertig, wenn:** `docs/ENTSCHEIDUNG.md` mit Messwerten vorliegt und Engine und Hülle
  gewählt sind.

### Phase 1 – Benutzbarer Browser auf macOS (4–6 Wochen)
- Tabs in der Seitenleiste, Befehlsleiste, Verlauf, Lesezeichen, Downloads, Sitzung
  wiederherstellen, Suche in der Seite, privates Fenster.
- Werbeblocker (`adblock-rust` wandelt Filterlisten ins Apple-Format um [belegt];
  Grenze laut Apple-Forum rund 150.000 Regeln).
- Schlafende Tabs und RAM-Anzeige.
- **Fertig, wenn:** du ihn eine Woche als Hauptbrowser nutzt und die Mängelliste steht.

### Phase 2 – Erweiterungen und Passwörter (3–4 Wochen)
- Erweiterungen installieren, verwalten, Rechte anzeigen, Symbolleiste und Popups.
- Bitwarden mit Vaultwarden von Anfang bis Ende: anmelden, ausfüllen, speichern.
- Lokaler Passwort-Speicher über den System-Schlüsselbund mit Ausfüllen und Speichern.
- **Fertig, wenn:** Bitwarden und der lokale Speicher auf 20 Login-Seiten funktionieren.

### Phase 3 – Sync (2–3 Wochen)
- Sync-Server, Koppeln per QR-Code, Lesezeichen, Tabs, Einstellungen.
- Import aus Chrome, Firefox, Safari.
- **Fertig, wenn:** zwei Geräte über einen selbst gehosteten Server zuverlässig
  abgleichen und der Server nachweislich nur verschlüsselte Daten sieht.

### Phase 4 – Öffentliche Alpha (2 Wochen)
- Signieren und Notarisieren, automatische Updates, Webseite, Quelltext öffnen,
  Beitragsregeln, Leistungs-Obergrenzen als automatische Prüfung.
- Start bei Hacker News, GitHub, Reddit. Texte als Entwurf, du postest.
- **Fertig, wenn:** Fremde die App laden, nutzen und Fehler melden können.

### Phase 5 – KI-Schicht (4–5 Wochen)
- MCP-Server mit Rechte-Modell, Protokoll und Stopp-Knopf; Testsammlung mit 10 Aufgaben.
- Seite zusammenfassen und befragen, semantischer Verlauf.
- **Fertig, wenn:** Claude Code die 10 Aufgaben zuverlässig löst, keine gesperrte Seite
  erreicht wird und die Verlaufs-Suche ohne Internet funktioniert.

### Phase 6 – iOS
- Gleiche Swift-Basis und derselbe Kern. Erweiterungen ab iOS 18.4.

### Phase 7 – Linux und Windows
- Rust-Hülle. Windows mit WebView2, Linux mit WebKitGTK. Erweiterungen dort
  eingeschränkt; falls nötig eigene Entscheidung über eine andere Engine.

### Phase 8 – Android
- Kotlin-Hülle. GeckoView, falls Erweiterungen dort wichtig sind.

Die KI-Schicht steht bewusst nach der Alpha, weil der Browser zuerst als Browser
überzeugen soll. Wenn du lieber früher mit Agenten zeigen willst, lässt sich der
MCP-Server aus Phase 5 direkt nach Phase 1 vorziehen.

---

## 7. Risiken

| Risiko | Gegenmittel |
|---|---|
| Zu wenige Erweiterungen laufen auf WebKit | Phase 0 misst es, bevor Wochen investiert sind; Entscheidung mit Zahlen |
| Apple gibt Freigaben nicht an Einzelpersonen | In Phase 0 klären; Passkeys über Bitwarden; notfalls später als Organisation anmelden |
| Erweiterungen funktionieren nur auf Apple-Geräten gut | Offen kommunizieren; eingebaute Funktionen decken das Wichtigste überall ab |
| Passwort-Speicher oder Sync hat eine Lücke | Nichts Eigenes bei Krypto, System-Schlüsselbund, Server sieht nur Verschlüsseltes, später externe Prüfung |
| Agent wird durch Seiteninhalt manipuliert | Eigenes Profil, Rechte pro Website, Nachfrage bei Folgen, standardmäßig aus |
| Mehrere Hüllen sind viel Arbeit | Kern einmal in Rust; macOS und iOS teilen sich die Hülle; andere Plattformen erst nach der Alpha |
| Projekt bleibt unbemerkt | RAM-Vergleich als klare Botschaft, früh öffentlich, Community einbinden |
| Zeit und Token-Limit | Eine Sitzung pro Teilaufgabe, CODEMAP und HANDOFF pflegen |

**Abbruchpunkte:** nach Phase 0 (Messwerte tragen den Plan nicht) und drei Monate nach
der Alpha (unter etwa 1.000 GitHub-Sternen oder 200 wöchentlichen Nutzern heißt umdenken).

---

## 8. Erweiterungs-Test für Phase 0

Bitwarden, 1Password, uBlock Origin Lite, Dark Reader, SponsorBlock, Vimium,
Tampermonkey, React Developer Tools, Return YouTube Dislike, Stylus, Grammarly oder
LanguageTool, Raindrop, Wappalyzer, JSON-Viewer, ein Übersetzer.
Pro Erweiterung: lädt sie, zeigt sie ihr Popup, erfüllt sie ihre Hauptaufgabe.

---

## 9. Entscheidungen

Getroffen am 13.11.2026:
- **Name:** NeuralBrowser.
- **Lizenz:** MPL-2.0 (Änderungen am Code bleiben offen).
- **KI-Schicht:** nach der Alpha, wie im Fahrplan.
- **Design:** zuerst minimal mit Grundfunktionen und nativer macOS-Optik. Das Feindesign
  mit den NeuralHub-Farben und -Abständen folgt, wenn der Browser läuft.

Noch offen:
- Nach Phase 0: Leichtigkeit oder Erweiterungs-Abdeckung, falls der Test knapp ausfällt.

## 10. Was auf dem Mac noch fehlt

- Installiert: Swift 6.3 (Kommandozeilen-Werkzeuge), Rust 1.99, macOS 27. Das reicht, um
  die macOS-App zu bauen (über SwiftPM, ohne Xcode-Projekt).
- **Xcode** (App Store) wird für iOS, für den Simulator und für das Notarisieren gebraucht.
- **rustup** wird für iOS- und Android-Ziele gebraucht (Rust kommt bisher über Homebrew).
- **Apple-Entwicklerkonto** wird für die öffentliche Alpha gebraucht (Signieren).
