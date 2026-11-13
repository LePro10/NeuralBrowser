# Erweiterungs-Test: Laufen gängige Erweiterungen auf WebKit?

Stand: 13.11.2026 · macOS 27.0.1 (arm64) · NeuralBrowser-Prototyp (`apps/apple`, Branch `extension-test`)
Frage aus `docs/PLAN.md` Abschnitt 3 und 8: Reicht Apples `WKWebExtension` für die 15 wichtigsten Erweiterungen?

**Kurzantwort:** Nein, nicht ohne Nacharbeit. Von 10 getesteten Erweiterungen erfüllen **4 ihre Hauptaufgabe
unverändert**, 1 teilweise. Bitwarden läuft als unverändertes Chrome-Paket **nicht** (Popup ja, Formularerkennung nein).
Mit kleinen Text-Korrekturen am Erweiterungs-Code wären es 6 (+1 teilweise). Die Entscheidungsregel
(12 von 15 inklusive Bitwarden) ist **nicht erfüllt**.

## 1. Ergebnistabelle

Stufe 1 = lädt · Stufe 2 = Hintergrund startet, Popup/Optionsseite zeigen Inhalt · Stufe 3 = Hauptaufgabe auf echter Seite.
Kategorien: **W** = WebKit kann es nicht · **A** = unsere App kann es (noch) nicht · **E** = Erweiterung selbst (z. B. nur für Chrome/Safari-App gebaut).

| # | Erweiterung | Quelle | Version | MV | Stufe 1 | Stufe 2 | Stufe 3 | Ursache bei Problemen | Kat. |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Bitwarden | GitHub `bitwarden/clients`, Release `browser-v2026.10.2`, `dist-chrome-2026.10.2.zip` | 2026.10.2 | 3 | ja | ja¹ | nein (mit 1 Patch: teilweise) | Hintergrund nutzt `chrome.scripting.ExecutionWorld.ISOLATED` → fehlt in WebKit → Autofill-Skripte werden nie eingespritzt. Mit Text-Patch (Konstante durch `"ISOLATED"`/`"MAIN"` ersetzt) erkennt das Content-Script das Login-Formular (E-Mail + Passwort, 1 Formular). Popover schließt sich nach ~1 s wieder (Seite im Tab geht). | W (+A beim Popover) |
| 2 | uBlock Origin Lite | GitHub `uBlockOrigin/uBOL-home`, `uBOLite_2026.1110.1816.chromium.zip` | 2026.1110.1816 | 3 | ja | ja | **ja** | Netzwerk-Blockieren (DNR) wirkt erst ~10 s nach dem ersten Start (Regeln werden kompiliert). Generisches kosmetisches Filtern auf der Testseite nicht beobachtet. | – |
| 3 | Dark Reader | GitHub `darkreader/darkreader`, `darkreader-chrome-mv3.zip` | 4.9.135 | 3 | ja | ja | **ja** | Testseite und Wikipedia dunkel (`body` von `rgb(255,255,255)` auf `rgb(24,26,27)`). Nur `fontSettings` ignoriert. | – |
| 4 | SponsorBlock | GitHub `ajayyy/SponsorBlock`, `ChromeExtension.zip` | 6.1.7 | 3 | ja | ja | teilweise | Auf YouTube: Player-Knöpfe, Vorschaubalken, Kategorie-Pill eingefügt; Popup erkennt das Video und fragt den Server ab („No segments found“). Das eigentliche Überspringen nicht beobachtet (Testvideo ohne Segmente). | – |
| 5 | Vimium | GitHub `philc/vimium`, Tag `v2.4.2` (Quellcode = entpackte Erweiterung) | 2.4.2 | 3 | ja² | nein | nein (mit 2-Zeilen-Patch: **ja**) | `chrome.webNavigation.onHistoryStateUpdated` fehlt → Hintergrund stirbt → Tasten tun nichts. Mit `?.` an zwei Stellen: `f` zeigt Link-Hinweise, `j` scrollt. | W |
| 6 | Violentmonkey | GitHub `violentmonkey/violentmonkey`, `Violentmonkey-mv3-v2.50.0.zip` (zusätzlich MV2 `…-webext-v2.50.0.zip`) | 2.50.0 | 3 (2) | ja | teilweise | nein | `browser.notifications` fehlt → Hintergrund stirbt (MV3 und MV2). MV3 braucht zusätzlich `userScripts`, das WebKit nicht hat. MV2 mit Benachrichtigungs-Attrappe: Hintergrund startet, scheitert dann an `permissions.contains("downloads")` (WebKit wirft Fehler statt `false`). Testskript lief nicht. | W |
| 7 | Stylus | GitHub `openstyles/stylus`, `stylus-chrome-mv3-v2.4.18-id.zip` | 2.4.18 | 3 | ja | nein | nein | `permissions.contains("webRequestBlocking")` wirft → Hintergrund stirbt. Nach 2 Patches startet er, scheitert aber an `webRequest`-Konstanten, `idle`, Installation über DNR-Umleitung. Stil wurde nicht angewendet. | W |
| 8 | Return YouTube Dislike | GitHub `Anarios/return-youtube-dislike`, `return-youtube-dislike-chrome-4.1.7.zip` | 4.1.7 | 3 | ja | ja | nein | Content-Script läuft (Listener registriert), API ist erreichbar (aus Seite und Erweiterungsseite: HTTP 200), aber die Dislike-Zahl erscheint nicht (2 Videos, 25 s gewartet, auch mit Chrome-Kennung). Ursache **nicht geklärt**. | unklar |
| 9 | JSON-Viewer: JSONVue | GitHub `gildas-lormeau/JSONVue`, Commit `21f3086` (Ordner `src`, kein Build nötig) | 0.2.3 | 3 | ja | ja (hat kein Popup) | **ja** | `data.json` wird als einklappbarer Baum angezeigt (ohne Erweiterung: rohes `<pre>`). | – |
| 10 | Übersetzer: TWP | GitHub `FilipePS/Traduzir-paginas-web`, `TWP_10.2.1.0_Chromium_MV2_deprecated.crx` | 10.2.1.0 | 2 | ja | ja (2 Fehler) | **ja** | Deutsche Testseite per Popup-Knopf ins Englische übersetzt. Fehler im Hintergrund (`runtime.onUpdateAvailable` fehlt, `ftp://`-Muster abgelehnt) stören die Hauptfunktion nicht. Paket ist MV2 („deprecated“). | (W, harmlos) |
| 11 | React Developer Tools | – | – | – | nicht getestet | – | – | Kein offizielles Paket außerhalb des Chrome Web Store; Selbstbau braucht das ganze React-Monorepo. Hängt außerdem an `chrome.devtools`, das WebKit-Erweiterungen nicht haben (Annahme, nicht geprüft). | – |
| 12 | LanguageTool | – | – | – | nicht getestet | – | – | Nur im Store erhältlich (offenes Repo `languagetool-browser-addon` ist veraltet). | – |
| 13 | Raindrop.io | – | – | – | nicht getestet | – | – | Nur im Store erhältlich. | – |
| 14 | Wappalyzer | – | – | – | nicht getestet | – | – | Nur im Store erhältlich (Quellcode seit 2023 nicht mehr offen). | – |
| 15 | 1Password | – | – | – | nicht getestet | – | – | Nur im Store erhältlich; braucht die 1Password-App (Native Messaging). | – |

¹ Bitwarden-Hintergrund startet nur, weil unsere App jetzt eine Browser-Kennung im User-Agent der Erweiterungs-Webviews setzt
(siehe 4.). Vorher: Absturz (`this.device.toString` von `null`).
² Vimiums `manifest.json` im Quell-Repo enthält Kommentare; WebKit lehnt sie ab („Unable to parse manifest“), Chrome nicht.
Getestet mit kommentarfreiem Manifest – genau das erzeugt auch Vimiums eigenes Build-Skript (`make.js`).

**Safari-Pakete der Hersteller** (zusätzlich notiert): uBOL bietet auf GitHub `uBOLite_….safari.zip` an – getestet, gleiches
Ergebnis wie das Chromium-Paket. SponsorBlock bietet `SafariExtension.zip` (MV2) an – lädt in Stufe 1 fehlerfrei.
Bitwarden, 1Password und Dark Reader gibt es für Safari nur in ihren Mac-App-Store-Apps (nach meinem Wissen, nicht geprüft);
solche App-Erweiterungen kann ein fremder Browser nicht laden. Für Vimium, Violentmonkey, Stylus, JSONVue und TWP ist mir
kein offizielles Safari-Paket bekannt.

Prüfsummen (SHA-256, Anfang): Bitwarden `2ebc6124…`, uBOL `85fe5909…`, Dark Reader `6c59ba11…`, SponsorBlock `7c8e3dc8…`,
Violentmonkey MV3 `72f1de5a…`, Stylus `1700f5f8…`, RYD `c63456be…`, TWP `bb2e9dee…`, Vimium-Tarball `c47b11b7…`.

## 2. Zählung

- **Unverändert: 4 von 10 getesteten erfüllen ihre Hauptaufgabe** (uBOL, Dark Reader, JSONVue, TWP), 1 teilweise (SponsorBlock).
- Gemessen an der Zielmenge: **4 von 15**, Bitwarden **nicht** dabei.
- Mit kleinen Text-Patches am Erweiterungs-Code (nur als Experiment, Kopien außerhalb des Repos): 6 von 10
  (+ Vimium, + Bitwarden-Formularerkennung), + 1 teilweise.
- Selbst wenn alle 5 nicht getesteten liefen, käme man ohne Patches nur auf 10 von 15.

## 3. Die wichtigsten fehlenden WebKit-Funktionen (beobachtet)

| Fehlt / weicht ab | Trifft | Folge |
|---|---|---|
| `chrome.scripting.ExecutionWorld` (Konstante) | Bitwarden | Autofill-Skripte werden nicht eingespritzt |
| `chrome.webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated` | Vimium, Stylus | Hintergrund stirbt beim Start |
| `chrome.notifications` (ganz), `notifications.onClicked` | Violentmonkey, Bitwarden (nicht tödlich) | Hintergrund stirbt |
| `permissions.contains()` **wirft** bei unbekannter Berechtigung (Chrome: `false`) | Stylus, Violentmonkey | Hintergrund stirbt |
| `chrome.userScripts` | Violentmonkey MV3 (jeder MV3-Userscript-Manager) | grundsätzlich keine Userscripts unter MV3 |
| `webRequest`-Blockieren und -Konstanten, `idle`, `offscreen`, `sidePanel`, `identity`, `downloads`, `bookmarks`, `history`, `sessions`, `search`, `fontSettings`, `privacy` | viele (still ignoriert) | Teilfunktionen fehlen |
| `runtime.onUpdateAvailable`, `ftp://`-Muster in `menus.create` | TWP | nur Fehlermeldungen |
| `manifest.json` mit Kommentaren | Vimium (Quellcode) | lädt gar nicht |
| `commands` mit leerem `_execute_action` | Stylus, Violentmonkey | nur Warnung |

Wichtig für eine mögliche Kompatibilitätsschicht: Eine **fehlende** API (z. B. `notifications`) kann man zur Laufzeit
als Attrappe nachrüsten – das hat bei Violentmonkey funktioniert. Eigenschaften an **vorhandenen** API-Objekten
(`chrome.scripting.ExecutionWorld`, `chrome.permissions.contains`) lassen sich so nicht ändern; die Zuweisung „hält“
nicht. Dort hilft nur, den Code der Erweiterung beim Installieren umzuschreiben – fehleranfällig und bei jedem Update neu nötig.

## 4. Was unsere App schon nachgerüstet hat (in diesem Branch)

- **Browser-Kennung für Erweiterungs-Webviews** (Hintergrund, Popup, Optionen): ohne Kennung stürzte Bitwarden ab;
  mit Safari-Kennung glaubt Bitwarden, es laufe in Safari, wartet auf seine Mac-App (`sendNativeMessage`) und
  hängt mit 100 % CPU – dann laden nicht einmal seine Seiten. Jetzt: `Chrome/142.0.0.0 Safari/605.1.15`
  (Testschalter `--extension-ua`, `--tab-ua`).
- **Testprofil statt Nutzerprofil:** Selbsttests nutzen jetzt auch für Cookies/Caches einen reinen Arbeitsspeicher-Speicher
  (vorher `WKWebsiteDataStore.default()` = echte Cookies). `--data-dir` bekommt eigenen WebKit-Speicher und eigenen
  Erweiterungsspeicher.
- **Testwerkzeug `--ext-script`:** Seiten öffnen, JavaScript auswerten (Seite, Popup, Hintergrund), echte Tasten und Klicks,
  Popup öffnen, Erweiterungsseiten (`ext:ORDNER/@options`, `@popup`) im Tab, Bildschirmfotos, Fehlerliste je Erweiterung.
  `--extension-report` bricht hängende Hintergründe nach 20 s ab statt endlos zu warten. JS-Dialoge blockieren Tests nicht mehr.

## 5. Was unsere App noch nachrüsten muss

1. **Popover-Verhalten** prüfen: Bitwardens Popup schließt sich nach ~1 s (Dark Reader, uBOL, SponsorBlock nicht).
2. **Native Messaging** (`sendNativeMessage`) fehlt im Delegate – nötig für 1Password, Bitwarden-Biometrie, KeePassXC u. ä.
3. **Installationsweg:** zip/crx entpacken (crx = zip mit Kopf, `unzip` reicht), Manifest-Kommentare entfernen,
   Updates prüfen, Berechtigungen pro Website statt pauschal.
4. Optional eine **Kompatibilitätsschicht** (Attrappen für fehlende Namensräume, gezielte Patches) – nur wenn bewusst
   gewollt; wartungsintensiv.
5. Erweiterungsseiten im Tab (Dashboards, Optionen) funktionieren bereits; Tab-/Fenster-Ereignisse kamen an.

## 6. Wie Erweiterungen später installiert werden könnten

- **GitHub-Releases der Hersteller** (zip/crx der Chrome-Builds): für Open-Source-Erweiterungen der sauberste Weg; so wurde hier getestet.
- **Safari-zips einzelner Hersteller** (uBOL, SponsorBlock) laden ebenfalls direkt.
- **Chrome Web Store:** CRX-Download über die Update-Schnittstelle ist technisch möglich, rechtlich/vertraglich
  heikel; Store-only-Erweiterungen (1Password, Raindrop, Wappalyzer, LanguageTool) gäbe es nur so.
- **Firefox Add-ons (xpi):** oft MV2 mit Firefox-Eigenheiten; nicht getestet.
- **Safari-App-Store-Erweiterungen** (in Mac-Apps eingebettet) sind für einen fremden Browser nicht nutzbar.

## 7. Empfehlung zur Entscheidungsregel

**Die Regel „mindestens 12 von 15 inklusive Bitwarden“ ist nicht erfüllt (4 von 15, Bitwarden nein).
Weg A ist damit nicht bestätigt.** Laut Plan entscheidest du jetzt mit den Zahlen.

Meine Einschätzung dazu: Die Ausfälle sind meist **kleine API-Lücken** (eine fehlende Konstante, ein fehlendes Ereignis,
eine Funktion, die wirft statt `false` zu liefern), keine grundsätzliche Unfähigkeit – aber wir können sie nicht selbst
in WebKit schließen, und eine Kompatibilitätsschicht im Browser ist Dauerpflege. Grundsätzlich fehlen `userScripts`
(Userscript-Manager unter MV3) und blockierendes `webRequest`. Gerade diese Bereiche (Userscripts, eigene Stile,
Werbeblocker, Passwörter) will der Plan ohnehin fest einbauen. Wenn dir „die Erweiterung X läuft sicher“ wichtiger ist
als Leichtigkeit, spricht das Ergebnis für Weg B/C. Wenn Leichtigkeit vorgeht: Weg A nur mit kuratierter Liste
(heute: uBOL, Dark Reader, JSON-Viewer, Übersetzer, teils SponsorBlock), eingebauten Ersatz-Funktionen, und Bitwarden
erst nach einer Korrektur bei Bitwarden oder Apple (Fehler melden: `ExecutionWorld`, `permissions.contains`,
`webNavigation.onHistoryStateUpdated`, `notifications`).

## 8. Wie belastbar ist das Ergebnis?

- Ein Rechner, eine macOS-/WebKit-Version (27.0.1). Neuere WebKit-Versionen können Lücken schließen – Test lässt sich mit
  den Werkzeugen oben in Minuten wiederholen.
- Meist ein bis drei Läufe je Test; Testseiten lokal (Login-Formular, Werbe-Testseite, JSON, deutsche Seite), dazu
  echte Seiten (Wikipedia, Spiegel, YouTube mit abgelehntem Cookie-Banner).
- Fehler aus dem Inneren der Erweiterungen sehe ich nur, wenn sie ungefangen sind (`context.errors`); eine Konsole
  wie im Web-Inspektor gab es nicht. Bei RYD ist die Ursache darum offen.
- Einige Prüfungen nutzen interne Schnittstellen der Erweiterungen (Bitwarden `collectPageDetailsImmediately`,
  Stylus-`API`, Violentmonkey `ParseScript`), weil ohne Anmeldung bzw. Bedienoberfläche nichts anderes ging.
- Der TWP-Übersetzen-Knopf wurde per JavaScript geklickt, nicht per Maus; Tasten und Klicks auf Seiten waren echte Ereignisse.
- Patches wurden nur an Kopien im temporären Ordner gemacht und zählen **nicht** als „läuft“.

**Nur ein Mensch mit Anmeldung kann prüfen:** Bitwarden (Entsperren, Ausfüllen, „Login speichern?“-Leiste, Passkeys),
1Password, Raindrop, LanguageTool (Konto-Funktionen), RYD-Premium, SponsorBlock-Einreichungen. Ebenso das echte Klick-Gefühl
der Popups und Tastenkürzel im Alltag.

## 9. Nachmessung mit Übersetzer (13.11.2026, Regelsatz 2)

Alle Pakete wie oben (gleiche Dateien, SHA-256 geprüft) über den neuen Installationsweg
(`--install-extension`, gleiche Logik wie „Install Extension…“) installiert und mit `--ext-script`
gemessen, Testseiten lokal (`127.0.0.1:8765`), temporäre Profile. Gegenprobe jeweils mit dem
unveränderten Paket (`original/`) im selben Lauf-Aufbau.

| # | Erweiterung | vorher (unverändert) | nachher (übersetzt) | Was der Übersetzer geändert hat / Beleg |
|---|---|---|---|---|
| 1 | Bitwarden | Stufe 3 nein | **teilweise** | Original: `TypeError … chrome.scripting.ExecutionWorld.ISOLATED`, Autofill-Skript nicht eingespritzt. Übersetzt: keine Hintergrund-Fehler, `bitwardenAutofillInit` im Tab vorhanden, `getPageDetails()` liefert 1 Formular, Felder `email`, `password`. Popup zeigt Startseite und „Log in“; Anmeldeseite und Dialog „Self-hosted environment / Server URL“ einmal erreicht, Speichern nicht belegt. Popover bleibt offen (siehe unten). |
| 2 | uBlock Origin Lite | ja | ja | Blockieren wie Original (adsbygoogle, ga, gpt blockiert). |
| 3 | Dark Reader | ja | ja | Testseite und Wikipedia dunkel (`rgb(24,26,27)`), wie Original. |
| 4 | SponsorBlock | teilweise | teilweise | Popup und Optionen wie Original; YouTube nicht neu gemessen. |
| 5 | Vimium | nein (Manifest mit Kommentaren lädt nicht) | **ja** | 20 Kommentare entfernt, Hintergrund läuft, keine Fehler, `f` zeigt Link-Hinweise (Bildschirmfoto). `j` scrollte in einem frühen Lauf (240 px); spätere Läufe liefen bei gesperrtem Bildschirm (s. u.). |
| 6 | Violentmonkey MV2-Paket | nein | **ja** | Testskript über die interne Schnittstelle installiert, lief auf der Seite (`data-nb-userscript="ran"`), Popup listet es. |
| 6 | Violentmonkey MV3-Paket | nein | nein | `userScripts` fehlt in WebKit – nicht übersetzbar. |
| 7 | Stylus | nein | nein | Manager und Popup öffnen, Stil-Installation scheitert, kein Stil angewendet (`apply.js: data.cfg` undefined). |
| 8 | Return YouTube Dislike | nein | nein | unverändert, Ursache weiter offen. |
| 9 | JSONVue | ja | ja | Baumansicht wie vorher. |
| 10 | TWP | ja (2 Fehler) | ja (1 Fehler) | `runtime.onUpdateAvailable`-Fehler weg; Übersetzen im ersten Lauf belegt. |

**Neue Zählung:** 6 von 10 erfüllen ihre Hauptaufgabe (vorher 4), 2 teilweise (SponsorBlock,
Bitwarden). Gemessen an 15: 6 von 15; Bitwarden nur teilweise, die Regel „12 von 15 inkl.
Bitwarden“ bleibt verfehlt.

**Wichtige technische Befunde beim Bau des Übersetzers (gemessen):**
- WebKits Namensraum-Objekte (`chrome.webNavigation` usw.) werden nach einer Speicherbereinigung
  neu erzeugt: eine dort angehängte Eigenschaft war nach GC weg (Grund für „Zuweisung hält nicht“
  im Abschnitt 3). Die Namensräume auf `chrome` sind nicht ersetzbar, `globalThis.chrome` selbst
  aber schon. Das Vorschalt-Skript ersetzt deshalb **einen** der Globals durch einen Proxy.
- Werden **beide** Globals (`chrome` und `browser`) ersetzt, stellt WebKit keine Ereignisse mehr zu
  (`runtime.onMessage`, `webNavigation.*` kamen im Service Worker nie an; mit nur einem ersetzten
  Global ja). Der Übersetzer wählt den Namen, den der Code häufiger benutzt, und lenkt den anderen
  per Textregel um (Violentmonkey: `browser`, alle anderen: `chrome`).
- Fehlende Namensräume (z. B. `notifications`) lassen sich direkt am echten API-Objekt ergänzen; das hält.

**Popover schließt sich (App-Fehler, behoben):** Ursache belegt mit Stapel beim
`NSPopover.willClose`: `-[NSView removeFromSuperview]` (unser `SidebarView.setExtensionButtons`) →
`_geometryInWindowDidChangeForView:` → `-[NSPopover performClose:]`. Bitwarden ändert beim Öffnen
das Aktionssymbol, die App baute daraufhin alle Erweiterungsknöpfe neu auf und entfernte damit den
Anker des Popovers. Mit altem Code schloss sich das Popover nach 344 ms; mit der Korrektur (Knöpfe
werden an Ort und Stelle aktualisiert) blieb es in 3 von 3 Läufen ≥ 6 s offen.

**Offen / Einschränkungen dieser Nachmessung:**
- ~~Gesperrter Bildschirm als Ursache~~ **korrigiert (13.11.2026, Nachuntersuchung):** Die
  Hintergründe hörten nicht wegen des gesperrten Bildschirms auf zu antworten. Ursache ist WebKits
  Tracking-Schutz (ITP): Er behandelt die Herkunft einer Erweiterung (`webkit-extension://<uuid>`)
  wie eine Website ohne Nutzer-Interaktion und löscht deren Skript-Speicher, damit auch die
  Service-Worker-Registrierung des Hintergrunds (Log: `deleteAndRestrictWebsiteDataForRegistrableDomains`
  → `SWServerRegistration::clear` → `SWContextManager::terminateWorker`, ca. 5 s nach Start). WebKit
  startet den Hintergrund nicht neu; Popups bekommen „port is disconnected“ und zeigen nur den
  Ladekreis. Das traf alle Erweiterungen gleich, auch unveränderte Pakete. Zusätzlich lagen die
  Erweiterungsseiten wegen eines Konfigurationsfehlers auch in Selbsttests im **echten**
  Standard-Datenspeicher; dessen ITP-Datenbank war seit dem Mittag „gealtert“ (100 von 122
  Erweiterungs-Herkünften mit `dataRecordsRemoved` > 0). Behoben: eigener Datenspeicher für
  Erweiterungsseiten im Speicher der Tabs; vor dem Laden und bei jedem Klick auf das Symbol wird für
  die Erweiterungs-Herkunft eine Nutzer-Interaktion bei ITP vermerkt
  (`ExtensionManager.exemptFromTrackingPrevention`), ITP bleibt für Websites an. (Ein erster Fix mit
  eigenem Speicher ohne ITP brach die Nachrichten Content-Script → Hintergrund, siehe HANDOFF.) Nachweis
  mit `apps/apple/scripts/ext-normal-test.sh` (Bitwarden mit eingespielter gealterter ITP-Datenbank:
  nach Installation, Neustart und 3 min Popup mit Startseite, Autofill-Skript eingespritzt, Felder
  `email,password` erkannt; ITP lief, löschte aber 0 Herkünfte). Die oben als „bei
  gesperrtem Bildschirm“ markierten Messungen (Vimium `j` usw.) sollten neu gemessen werden.
- Bitwarden: Entsperren, Ausfüllen, „Login speichern?“, Passkeys und Vaultwarden-Anmeldung brauchen
  ein Konto – nicht geprüft. Speichern der Server-Adresse nicht belegt.
- uBOL „Complete“-Modus, Spiegel-Test und YouTube-Tests (SponsorBlock, RYD) wurden in der
  Nachmessung nicht neu bewertet bzw. scheiterten bei Original und Übersetzung gleich.
