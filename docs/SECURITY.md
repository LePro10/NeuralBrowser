# NeuralBrowser – Bedrohungsmodell und Sicherheitsregeln

Stand: 13.11.2026, Fassung 1 (Phase 0, vor dem ersten Feature). Grundlage: `docs/PLAN.md`.
Kennzeichnung: **[prüfen]** = technische Annahme, die vor der Umsetzung belegt werden muss.
Dieses Dokument verspricht keine Sicherheit. Es legt fest, wovor wir schützen, wovor nicht,
und welche Regeln für jeden Beitrag gelten. Ändert sich die Architektur, wird es zuerst angepasst.

---

## 1. Was geschützt wird

| Wert | Warum wichtig | Wo er liegt |
|---|---|---|
| Sitzungs-Cookies und Logins | Wer sie hat, ist der Nutzer auf Mail, Bank, GitHub | WebKit-Datenspeicher pro Profil |
| Passwörter (lokaler Speicher) | Direkter Kontozugriff | System-Schlüsselbund |
| Verlauf, Lesezeichen, offene Tabs | Zeigt Interessen, Gesundheit, Arbeit, Kontakte | SQLite im Rust-Kern |
| Sync-Schlüssel | Öffnet alle synchronisierten Daten aller Geräte | System-Schlüsselbund |
| API-Schlüssel für KI-Anbieter | Kostet Geld, kann missbraucht werden | System-Schlüsselbund |
| MCP-Zugangs-Token | Erlaubt, den Browser fernzusteuern | System-Schlüsselbund |
| Einbettungen des semantischen Verlaufs | Lassen Rückschlüsse auf Seiteninhalte zu | Lokal im Kern |
| Integrität von App, Updates, Erweiterungen, Filterlisten | Wer hier etwas einschleust, hat alles oben | Build-Kette, Update-Server |

## 2. Angreifer und was sie können

| Angreifer | Fähigkeiten | Ziel |
|---|---|---|
| A1 Bösartige Webseite | Beliebiges HTML/JS, Frames, Pop-ups, Downloads, Weiterleitungen auf eigene URL-Schemata, Social Engineering | Cookies anderer Seiten, Passwörter per Phishing, Zugriff auf JS-Brücken |
| A2 Bösartige oder gekaperte Erweiterung | Alle bei der Installation gewährten Rechte; ein gekauftes oder gekapertes Konto liefert ein bösartiges Update | Inhalte aller erlaubten Seiten, Cookies, Passwörter beim Tippen |
| A3 Seiteninhalt gegen KI-Agent (Prompt Injection) | Text, versteckte Elemente, Bilder, Formulare, die das Modell als Anweisung liest | Agent soll Daten weitergeben, klicken, kaufen, senden |
| A4 Lokaler Prozess, gleicher Nutzer | Kann Ports auf localhost ansprechen, Dateien im Nutzerordner lesen, ohne Admin-Rechte | MCP-Server steuern, Profil-Dateien lesen |
| A5 Angreifer im Netz | Mitlesen, Umleiten, DNS fälschen, öffentliches WLAN | Sync-Verkehr, Updates, Filterlisten, KI-Anfragen |
| A6 Neugieriger oder gehackter Sync-Server | Sieht und ändert alles, was er speichert; kann Daten löschen, zurückspielen, zurückhalten | Inhalte lesen, Metadaten sammeln, alte Stände unterschieben |
| A7 Verlorenes oder gestohlenes Gerät | Physischer Zugriff, eventuell entsperrt | Logins, Passwörter, Sync-Zugang |
| A8 Lieferkette | Manipulierte Rust-Crate oder Swift-Paket, gekaperter Build-Rechner oder Update-Schlüssel | Schadcode in jeder installierten Kopie |

## 3. Vertrauensgrenzen

```
 [Sync-Server]  untrusted, sieht nur Chiffrat + Metadaten
       |  TLS + Ende-zu-Ende-Verschlüsselung
 +-----+-------------------------------------------------------------+
 | Rust-Kern  (vertraut: store, sync, secrets, agent, mcp, ai)       |
 |      ^ UniFFI                         ^ Token-geprüfter Kanal     |
 | Native Hülle (Swift, vertraut)        |  [Lokale MCP-Clients]     |
 |   |       |          |                    untrusted bis Token ok  |
 |   |       |          +--> [System-Schlüsselbund]  (OS-geschützt)  |
 |   |       +-- Brücken (prüfen Herkunft) --+                        |
 |   v                                       |                        |
 | [Webinhalt]   untrusted, WebKit-Prozesse, Sandbox vom OS          |
 | [Erweiterungen] halb vertraut, nur gewährte Rechte                |
 | [Agent/Modell]  untrusted Entscheidungen, nur über Rechte-Modell  |
 +-------------------------------------------------------------------+
```

Grundsatz: Webinhalt, Erweiterungen und Agent sind drei getrennte Stufen. Nichts, was aus
einer niedrigeren Stufe kommt, wird ungeprüft ausgeführt oder als Befehl behandelt.
Agent-Entscheidungen gelten als untrusted, weil das Modell Seiteninhalt (A3) liest.

## 4. Bausteine: Bedrohung, Gegenmaßnahme, Restrisiko

### 4.1 Hülle und WebView-Konfiguration

| Bedrohung | Gegenmaßnahme | Restrisiko |
|---|---|---|
| Seite ruft JS-Brücke (`WKScriptMessageHandler`) auf und löst Kern-Funktionen aus | Brücken nur in eigener `WKContentWorld`, nicht in der Seitenwelt [prüfen]; jede Nachricht prüft `frameInfo.securityOrigin` und `isMainFrame`, feste Nachrichtentypen, Schema-Prüfung, keine generische "führe aus"-Brücke | Fehler in einer einzelnen Brücke; WebKit-Lücke, die die Welt-Trennung umgeht |
| Eigenes URL-Schema (`neuralbrowser://`, `WKURLSchemeHandler`) wird von Webseiten aufgerufen | Interne Seiten nur aus der Hülle ladbar, nicht per Link oder Weiterleitung aus Webinhalt; Handler liefert nur statische, gebündelte Dateien; keine Aktionen per URL-Parameter | Fehlkonfiguration bei neuen Seiten |
| Externe Schemata (`mailto:`, `file:`, App-Schemata) starten Programme | Immer Nachfrage mit vollem Ziel; `file:` aus Webinhalt gesperrt | Nutzer bestätigt eine Täuschung |
| Download legt Schadsoftware ab oder überschreibt Dateien | Nur in den Download-Ordner, Dateiname bereinigt, keine Überschreibung, Quarantäne-Attribut setzen (Gatekeeper prüft beim Öffnen) [prüfen], nie automatisch öffnen | Nutzer öffnet bewusst eine Schaddatei |
| Privates Fenster hinterlässt Spuren | Eigener `WKWebsiteDataStore.nonPersistent()` [prüfen]; kein Verlauf, keine Einbettungen, kein Sync, Erweiterungen aus, Downloads bleiben (sichtbar kommuniziert) | Spuren im OS (Swap, DNS-Cache, Downloads); privat ist nicht anonym |
| Profile vermischen Cookies (Nutzer, Agent, privat) | Jedes Profil eigener Datenspeicher (`WKWebsiteDataStore(forIdentifier:)`, ab macOS 14 [prüfen]) | Fehler in WebKit-Trennung |
| Täuschung in der Oberfläche (falsche Adressleiste, Vollbild) | Adresse immer aus der Hülle, nie aus Seiteninhalt; Herkunft vor Pfad hervorgehoben; Hinweis beim Vollbild | Unicode-Doppelgänger in Domains; Anzeige als Punycode [prüfen] |
| Lücke in Swift- oder Rust-Code | Rust ohne `unsafe` außerhalb von `ffi/`; Hardened Runtime; App Sandbox als Ziel [prüfen] | Logikfehler bleiben möglich |
| Werbeblocker-Filterliste schleust Skripte ein (Scriptlets) | Filterlisten nur über HTTPS von festen Quellen; Scriptlets nur aus gebündelter, geprüfter Bibliothek | Gekaperte Listenquelle kann Seiten unbrauchbar machen |

### 4.2 Erweiterungen und Userscripts

| Bedrohung | Gegenmaßnahme | Restrisiko |
|---|---|---|
| Installation einer Schad-Erweiterung | Rechte vor der Installation in Klartext; Warnung bei "alle Seiten"; Herkunft (Ordner, Store, Datei) sichtbar | Nutzer stimmt zu; wir prüfen keinen Code |
| Zu weite Rechte | Seitenrechte standardmäßig "beim Klicken" statt "immer", sofern `WKWebExtension` das erlaubt [prüfen]; Rechte jederzeit entziehbar | Erweiterung funktioniert nur mit weiten Rechten |
| Gekapertes Update | Bei Updates nur neue Rechte anzeigen und neu zustimmen lassen; Update-Herkunft und Signatur prüfen, wo vorhanden [prüfen]; Updates abschaltbar | Bösartiges Update ohne neue Rechte fällt nicht auf |
| Erweiterung im Agenten-Profil oder privaten Fenster | Standardmäßig aus, nur einzeln freigebbar | – |
| Userscripts (eingebaut) laufen auf allen Seiten | Gleiche Regeln wie Erweiterungen: Treffer-Muster sichtbar, Herkunft angezeigt, Updates nur mit Anzeige der Änderung | Nutzer installiert fremdes Skript |
| Agent schreibt Plugins (Plan 4.3, Stufe 3) | Kein automatisches Installieren; Mensch sieht Code und Rechte und bestätigt; Plugins nur mit festen, kleinen Rechten | Nutzer bestätigt ungelesen |

### 4.3 Lokaler Passwort-Speicher und Ausfüllen

| Bedrohung | Gegenmaßnahme | Restrisiko |
|---|---|---|
| Phishing-Seite mit ähnlicher Domain | Ausfüllen nur bei exakt gleicher Herkunft (Schema + Host + Port); Subdomains nur, wenn beim Speichern ausdrücklich erlaubt; nie über HTTP | Nutzer tippt Passwort selbst ab |
| Unsichtbares Formular oder fremder Frame fängt Daten ab | Kein Ausfüllen in Frames anderer Herkunft als die Hauptseite; nie automatisch, nur nach Nutzeraktion; Feld muss sichtbar sein | Gekaperte Seite derselben Herkunft (XSS) bekommt das Passwort |
| Seite liest Passwort über die Brücke | Ausfüllen schreibt aus der Hülle in das Feld, keine Brücke gibt Passwörter an Seiten-JS zurück | Nach dem Ausfüllen kann Seiten-JS das Feld lesen (unvermeidbar) |
| Anderer Prozess liest den Schlüsselbund | Einträge mit Zugriffs-Regel an die signierte App gebunden, Entsperren per Touch ID/Gerätepasswort (`kSecAttrAccessControl`) [prüfen]; Linux Secret Service schützt schwächer, offen dokumentieren | Nicht signierte Entwickler-Builds haben schwächeren Schutz [prüfen] |
| Gestohlenes, entsperrtes Gerät | Erneute Abfrage von Touch ID vor dem Ausfüllen nach Ruhezeit; Passwort-Anzeige immer mit Abfrage | Angreifer mit entsperrtem Gerät und Gerätepasswort |
| Passwörter in Logs, Absturzberichten, Sync | Passwörter verlassen nie den Schlüsselbund-Pfad; nicht im Sync (Plan 4.4) | – |

### 4.4 Sync

Krypto-Kandidaten (nicht festgelegt, Auswahl in Phase 3 begründen): libsodium-Konstruktionen
(XChaCha20-Poly1305, X25519), RustCrypto-Crates `chacha20poly1305`/`x25519-dalek`, HPKE (RFC 9180),
für Gerätegruppen und Schlüsselwechsel MLS (RFC 9420, z. B. OpenMLS), für das Koppeln ein PAKE
(SPAKE2 oder CPace), Transport `rustls`. Nur Bibliotheken mit veröffentlichter Prüfung [prüfen].

| Bedrohung | Gegenmaßnahme | Restrisiko |
|---|---|---|
| Server liest Inhalte | Jeder Eintrag auf dem Gerät mit AEAD verschlüsselt; Server hat nie einen Schlüssel | Lücke in der gewählten Bibliothek oder ihrer Nutzung |
| Server ändert, vertauscht oder spielt alte Stände zurück | Eintrags-ID, Typ und Version als zusätzliche Daten (AAD) mitsigniert; Geräte merken sich die höchste gesehene Version und lehnen ältere ab | Server kann Daten zurückhalten oder löschen (nur Verfügbarkeit) |
| Koppeln per QR-Code wird abfotografiert oder abgefangen | QR enthält nur einen kurzlebigen Einmal-Code für ein PAKE oder einen Schlüssel für einen einmaligen Kanal, nicht den Dauerschlüssel; Bestätigung auf beiden Geräten mit Vergleichscode; Ablauf nach Minuten | Angreifer sieht Bildschirm und handelt im selben Moment |
| Fremder schreibt oder löscht auf dem Server | Jedes Gerät hat ein eigenes Schlüsselpaar und meldet sich damit an; der Server akzeptiert nur bekannte Geräte | Gehackter Server ignoriert das (nur Verfügbarkeit) |
| Gerät verloren oder entfernt | "Gerät entfernen" sperrt es am Server und erzeugt einen neuen Sync-Schlüssel für die übrigen Geräte; alte Daten neu verschlüsseln | Was das Gerät vorher hatte, bleibt in seiner Hand |
| Kompromittiertes Gerät ändert Sicherheits-Einstellungen aller Geräte | Sicherheits-Einstellungen (Agent-Rechte, MCP an/aus, Erweiterungen) werden nicht synchronisiert oder nur mit Bestätigung | – |
| Metadaten | Ehrlich: Der Server sieht IP-Adressen, Geräteanzahl, Zeitpunkte und Häufigkeit von Änderungen, Anzahl und ungefähre Größe der Einträge, und welcher Datentyp sich ändert, wenn Typen getrennt gespeichert werden. Gegen Größe: Auffüllen auf Blockgrößen [Ziel] | Nutzungsmuster bleiben erkennbar |

### 4.5 KI-Schicht und MCP-Server

| Bedrohung | Gegenmaßnahme | Restrisiko |
|---|---|---|
| Prompt Injection lässt Agent auf eingeloggte Konten zugreifen | Eigenes Agenten-Profil ohne Cookies des Nutzers; Rechte pro Website ("nie", "nur lesen", "bedienen mit Nachfrage", "frei"); Standard für unbekannte Seiten "nur lesen" | Agent missbraucht, was er auf freigegebenen Seiten darf |
| Agent schickt Daten von Seite A an Seite B (z. B. per URL-Parameter, Formular, Bild-Link) | Kein stiller Datenfluss: Navigation zu neuer Herkunft und jede Eingabe in Felder einer anderen Herkunft als der gelesenen braucht Nachfrage, wenn A nicht "frei" ist; Ausgabe des Seiten-Abbilds ohne versteckte Elemente | Daten im Modell-Kontext lassen sich nicht vollständig verfolgen |
| Aktionen mit Folgen | Absenden, Kaufen, Nachricht senden, Herunterladen, Rechte ändern: immer Bestätigung durch den Menschen in der Hülle, nicht im Seiteninhalt | Mensch bestätigt aus Gewohnheit |
| Fehleinstufung sensibler Seiten | Bank, Mail, Zahlung standardmäßig "nie" über eine gepflegte Liste; Seiten mit Passwort- oder Zahlungsfeldern gelten zusätzlich als sensibel | Liste ist nie vollständig |
| Lokaler Prozess (A4) oder Webseite steuert den MCP-Server | Bevorzugt stdio oder Unix-Socket mit Dateirechten nur für den Nutzer; falls HTTP: nur 127.0.0.1, zufälliges Token pro Client, Prüfung von `Host`- und `Origin`-Header gegen DNS-Rebinding; jeder Client einzeln freigegeben und widerrufbar | Prozess desselben Nutzers kann das Token aus dem Schlüsselbund oder der Konfiguration des Clients lesen [prüfen] |
| Agent arbeitet unbemerkt | Sichtbare Anzeige, solange ein Agent aktiv ist; Protokoll jeder Aktion (ohne Passwörter und Feldinhalte sensibler Felder); Stopp-Knopf beendet sofort alle laufenden Aktionen und trennt Clients | – |
| Seiteninhalt fließt an Cloud-Anbieter | Lokales Modell bevorzugt; Cloud nur mit eigenem Schlüssel, Anbieter sichtbar; Seiten auf "nie" und private Fenster werden nie gesendet, nie eingebettet | Anbieter speichert Anfragen nach eigenen Regeln |
| Externe MCP-Server (MCP-Client im Kern) | Gelten als fremder Code: einzeln hinzufügen, Werkzeuge anzeigen, Antworten als untrusted Inhalt behandeln | Bösartiges Werkzeug lügt in seinen Antworten |

### 4.6 Updates und Lieferkette

| Bedrohung | Gegenmaßnahme | Restrisiko |
|---|---|---|
| Gefälschtes Update | Updates signiert (Kandidat: Sparkle mit EdDSA-Signatur), zusätzlich Apple-Signatur und Notarisierung; nur HTTPS; kein Downgrade | Diebstahl des Signatur-Schlüssels |
| Signatur-Schlüssel gestohlen | Schlüssel nicht auf dem Entwicklungsrechner im Klartext; Hardware-Schlüssel oder Schlüsselbund; Plan für Schlüsseltausch dokumentiert | Einzelentwickler ist ein einzelner Ausfallpunkt |
| Manipulierte Abhängigkeit | `Cargo.lock` und `Package.resolved` eingecheckt; bei jedem Beitrag `cargo audit` und `cargo deny` (Lizenzen, Quellen, bekannte Lücken); neue Abhängigkeiten nur mit Begründung; `cargo vet` als Ziel | Neue, noch unbekannte Schad-Version |
| Gekaperter CI-Build | GitHub Actions auf feste Commit-Hashes gepinnt; minimale Token-Rechte; Build-Herkunft per Attestation [prüfen] | Kompromittierter GitHub-Account |
| Nicht nachprüfbarer Build | Reproduzierbare Builds als Ziel für den Rust-Kern und den Sync-Server (Docker-Abbild); für die signierte macOS-App schwierig [prüfen] | Nutzer müssen dem Build vertrauen |

## 5. Ausdrückliche Nicht-Ziele

1. Kein Schutz gegen Angreifer mit Admin-Rechten oder Schadsoftware, die als Nutzer schon läuft und den Schlüsselbund entsperrt nutzt.
2. Lücken in WebKit selbst flickt das Betriebssystem. Wer kein OS-Update einspielt, ist ungeschützt.
3. Kein vollständiger Schutz vor Prompt Injection. Wir begrenzen den Schaden, wir verhindern sie nicht.
4. Keine Anonymität wie bei Tor; kein Schutz vor Fingerprinting über das hinaus, was WebKit bietet.
5. Kein Schutz vor Erweiterungen, denen der Nutzer weite Rechte gegeben hat; keine Code-Prüfung fremder Erweiterungen.
6. Der Sync-Server muss nicht verfügbar sein; er kann Daten löschen oder zurückhalten.
7. Kein Schutz für Bitwarden, 1Password und andere Passwort-Erweiterungen über das Erweiterungs-Modell hinaus.
8. Kein Schutz vor Nutzern, die Warnungen bewusst wegklicken.

## 6. Verbindliche Regeln für alle Beiträge

Jede Regel ist im Review oder automatisch prüfbar. Ausnahmen nur mit Eintrag in diesem Dokument.

1. Keine eigene Kryptografie: keine eigenen Algorithmen, Protokolle oder Zufallsquellen; nur geprüfte Bibliotheken über deren High-Level-Schnittstelle.
2. Geheimnisse (Passwörter, Schlüssel, Tokens) nur im System-Schlüsselbund. Nie in Dateien, SQLite, Logs, Absturzberichten, Fehlermeldungen, Umgebungsdateien im Repo oder Tests.
3. Typen für Geheimnisse geben in `Debug`/`Display`/`description` nur `***` aus und werden nach Gebrauch gelöscht (Kandidat: `secrecy`/`zeroize`).
4. Jede JavaScript-Brücke prüft Herkunft und Frame, akzeptiert nur feste Nachrichtentypen mit Schema und läuft in einer eigenen Content World.
5. Daten aus Webinhalt, Erweiterungen, Agent, Sync-Server und MCP-Clients gelten als untrusted und werden vor Gebrauch geprüft.
6. Standard ist immer die sichere Einstellung: KI aus, Sync aus, MCP aus, Erweiterungen im Agent- und Privat-Profil aus.
7. Keine Netzwerk-Verbindung ohne dokumentierten Grund (Liste in `docs/NETZWERK.md`, wird mit der ersten eigenen Verbindung angelegt); keine Telemetrie; nur HTTPS.
8. `unsafe` in Rust nur in `core/ffi/` oder mit Begründung und Review.
9. Jede neue Abhängigkeit wird im Beitrag begründet; `cargo audit` und `cargo deny` müssen grün sein.
10. Aktionen mit Folgen (senden, kaufen, löschen, herunterladen, Rechte ändern) brauchen eine Bestätigung in der Hülle, nie per Seiteninhalt auslösbar.
11. Profile (Nutzer, Agent, privat) teilen keine Cookies, keinen Speicher und keine Erweiterungen.
12. Sicherheitsrelevante Änderungen (Brücken, Krypto, Schlüsselbund, MCP, Updates) brauchen einen Test für den Missbrauchsfall, nicht nur für den Normalfall.
13. Protokolle enthalten keine URLs aus privaten Fenstern, keine Feldinhalte und keine Geheimnisse.

## 7. Offene Sicherheitsfragen nach Phase

| Phase | Frage |
|---|---|
| 0 | Kann eine Brücke zuverlässig nur in einer eigenen `WKContentWorld` laufen, und wie zuverlässig ist `frameInfo.securityOrigin`? [prüfen] |
| 0 | Wird die App mit App Sandbox gebaut? Was bricht dann (Downloads, Erweiterungen, MCP-Socket)? |
| 0 | Welche Rechte-Steuerung bietet `WKWebExtension` (pro Seite, beim Klicken, Entzug)? |
| 1 | Trennung der Profile per `WKWebsiteDataStore(forIdentifier:)`, auch für Service Worker und Cache? |
| 1 | Quarantäne-Attribut bei Downloads; Darstellung von Unicode-Domains. |
| 1 | Welche Filterlisten und Scriptlets sind erlaubt, wie werden Listen-Updates geprüft? |
| 2 | Woher kommen Erweiterungs-Updates und gibt es eine prüfbare Signatur? Entpackte Pakete bekommen sonst keine Sicherheits-Updates. |
| 2 | Genaue Schlüsselbund-Regeln: Bindung an die App-Signatur, Touch ID, Verhalten bei Entwickler-Builds, Linux/Windows-Gegenstücke. |
| 3 | Wahl der Krypto-Bausteine und des Koppel-Verfahrens (PAKE vs. QR mit Einmal-Kanal); Schlüsselwechsel beim Entfernen eines Geräts; Schutz gegen Zurückspielen. |
| 3 | Welche Metadaten lassen sich mit vertretbarem Aufwand verringern (Auffüllen, gemeinsame Tabelle für alle Typen)? |
| 4 | Ablage und Ersatz des Update-Signatur-Schlüssels; Kontaktadresse; Release-Prozess bei Lücken. |
| 5 | Wie erhält das Agenten-Profil Zugriff auf eine eingeloggte Seite, ohne die Profil-Trennung zu brechen? |
| 5 | MCP-Transport (stdio, Unix-Socket, HTTP) und Token-Verwaltung; Regeln für den Datenfluss zwischen Websites. |
| 5 | Wer pflegt die Liste sensibler Seiten, und wie werden unbekannte Banken erkannt? |
| 6–8 | iOS-, Windows-, Linux- und Android-Gegenstücke aller Punkte; Linux Secret Service ist schwächer. |

Wird der MCP-Server wie im Plan erwähnt nach Phase 1 vorgezogen, wandern die Fragen aus Phase 5 mit.

## 8. Sicherheitslücken melden

- Bitte keine öffentlichen Issues für Lücken.
- Vorgeschlagener Weg: private Meldung über GitHub Security Advisories ("Report a vulnerability") im Repository.
- Alternativ per E-Mail: `[KONTAKTADRESSE EINTRAGEN]` (optional mit PGP-Schlüssel).
- Ziel: Eingangsbestätigung innerhalb von 7 Tagen, Behebung schwerer Lücken so schnell wie möglich, Veröffentlichung nach dem Fix in Absprache mit der meldenden Person. Es gibt keine Prämien.
- Unterstützt wird nur die jeweils neueste Version.
- Dieser Meldeweg gilt ab der ersten öffentlichen Version (Phase 4) und wird in `SECURITY.md` im Repo-Wurzelordner gespiegelt, damit GitHub ihn anzeigt.
