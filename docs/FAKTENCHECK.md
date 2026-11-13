# NeuralBrowser – Faktencheck und Marktlage

Stand: 13.11.2026. Prüfung des Ausgangstextes per Web-Recherche.
Kennzeichnung: **[belegt]** = mit Quelle geprüft, **[Einschätzung]** = mein Urteil, **[offen]** = nicht geprüft.
Hinweis: Ein Teil der Zahlen stammt aus Suchausschnitten, nicht aus vollständig gelesenen Quellen.

---

## 1. Faktencheck des Textes

| Behauptung | Urteil | Was stimmt |
|---|---|---|
| Oxide ist ein Rust-Browser mit GPUI, ideale Basis | **falsch als Basis** | Repo existiert (niklabh/oxide, 44 Sterne), nutzt GPUI und hat "Forge". Es hat aber "no DOM or layout engine" und führt nur WASM-Apps aus. Es zeigt keine normalen Webseiten. [belegt] |
| Obscura: Headless-Browser, ca. 35 MB RAM | **teilweise** | Existiert (ca. 34,6k Sterne, Apache-2.0, V8 für JavaScript). README nennt 30 MB, Tests 27–34 MB auf einfachen Seiten. Kein Fenster, und das Projekt räumt Abweichungen bei CSS, Web-APIs, Medien ein. [belegt] |
| Servo ist das mächtigste Fundament | **teilweise** | Aktiv, Linux Foundation Europe, v0.8.0 am 09.11.2026, läuft auf Windows, macOS, Linux, Android, OpenHarmony (kein iOS). Ob Alltagsseiten sauber laufen, ist nicht belegt. Kein DRM, keine Extensions bekannt. [belegt / offen] |
| Moto und Beaver bauen auf Servo auf | **unbelegt** | Nur aus Sekundärquellen. Das bekannteste Servo-Browser-Projekt Verso wurde am 08.10.2025 archiviert, Grund: zu wenig Leute und Geld. [belegt] |
| "Niemand baut von Null" | **falsch** | Ladybird baut eine komplett eigene Engine (noch kein Alpha, Stiftung mit Spenden). [belegt] |
| Rust eliminiert 70 % der Lücken "am Tag Null" | **verkürzt** | Die 70 % sind der Anteil von Speicherfehlern an schweren Lücken (Chromium, Microsoft, Zahlen von 2019/2020). Rust hilft dort, aber nicht in der JavaScript-Engine (Servo nutzt SpiderMonkey in C++), nicht in `unsafe`-Code und nicht bei den übrigen 30 %. [belegt + Einschätzung] |
| C++-Engines können nicht parallelisieren | **falsch** | Chromium und Firefox rechnen stark parallel. Firefox nutzt seit Jahren den parallelen CSS-Teil aus Servo. [Einschätzung, Allgemeinwissen] |
| Agent korrigiert, "bis alle Web Platform Tests grün sind" | **unrealistisch** | Die Testsammlung hat grob zwei Millionen Einzeltests. Keine Engine besteht alle, auch Chrome nicht. [Einschätzung] |
| Fable 5.2 designt das DOM "fehlerfrei", Browser für Einzelperson "absolut machbar" | **Werbesprache** | KI-Agenten beschleunigen Shell, Kern und Werkzeuge stark. Der Engpass einer Engine ist aber der endlose Rest an Web-Kompatibilität und das laufende Schließen von Sicherheitslücken. Das löst kein Modell in einem Rutsch. [Einschätzung] |
| Der Markt liegt bei Browsern für die KI-Ära | **teilweise** | Interesse ist da (Obscura 34,6k, Lightpanda ca. 42k Sterne). Bei Endnutzern zündet es bisher nicht, siehe Abschnitt 2. [belegt] |

---

## 2. Marktlage (Ende 2026)

- **Marktanteile** (StatCounter, Oktober 2026): Chrome 68,8 %, Safari 16,6 %, Edge 5,4 %,
  Firefox 2,6 %. KI-Browser tauchen nicht als eigene Einträge auf. [belegt]
- **ChatGPT Atlas eingestellt**: Ankündigung 09.07.2026, Funktionen wanderten in die
  Desktop-App und eine Chrome-Erweiterung. [belegt über zwei Berichte]
- **Comet** (Perplexity) und **Dia** (Atlassian, 610 Mio. USD Kaufpreis): Nutzerzahlen nur
  Schätzungen im einstelligen Millionenbereich. Beide Chromium. [teils belegt]
- **Die Großen bauen KI direkt ein**: Gemini in Chrome mit "Auto Browse", Brave Leo mit
  Agenten-Modus, Firefox mit KI-Fenster. Firefox musste nach Protest einen
  KI-Ausschalter einbauen (Firefox 148). [belegt]
- **Agenten-Infrastruktur** ist ein eigener, gut finanzierter Markt (Browserbase,
  Browser Use, Steel, Lightpanda, Obscura). [belegt]
- **Sicherheit ist ungelöst**: Trail of Bits zeigte bei Comet vier Prompt-Injection-Wege
  bis zum Abgreifen von Gmail. Brave und OpenAI sagen offen, dass das Problem nicht
  vollständig lösbar ist. [belegt]
- **Standards**: WebMCP ist noch ein Entwurf (Chrome-Test ab Version 149), kein
  W3C-Standard. llms.txt wird praktisch nicht abgerufen. [belegt]

**Was daraus folgt [Einschätzung]:**
1. Ein weiterer Chromium-KI-Browser für alle hat keine Chance gegen Chrome mit Gemini.
2. Ein weiterer Headless-Browser tritt gegen Projekte mit 35–40k Sternen und Geld an.
3. Frei ist die Mitte: ein **echter, sichtbarer Browser mit den Logins des Nutzers**, den
   ein Agent bedienen darf, aber nur in klaren Grenzen. Dazu lokal, ohne Konto, ohne Abo,
   KI komplett abschaltbar. Genau die Punkte Sicherheit und Kontrolle lösen die
   bisherigen Produkte schlecht.

---

## 3. Wichtigste Quellen

- Oxide: https://github.com/niklabh/oxide
- Obscura: https://github.com/h4ckf0r0day/obscura
- Lightpanda: https://github.com/lightpanda-io/browser
- Servo: https://servo.org/ , https://github.com/servo/servo/releases
- Verso (archiviert): https://github.com/versotile-org/verso
- Ladybird: https://ladybird.org/
- Atlas eingestellt: https://9to5mac.com/2026/07/09/openai-is-discontinuing-chatgpt-atlas-its-standalone-desktop-browser/
- Marktanteile: https://gs.statcounter.com/browser-market-share
- Comet-Audit: https://blog.trailofbits.com/2026/02/20/using-threat-modeling-and-prompt-injection-to-audit-comet/
- Brave zu Agenten-Sicherheit: https://brave.com/series/security-privacy-in-agentic-browsing/
- Speicherfehler-Anteil: https://www.chromium.org/Home/chromium-security/memory-safety/
- cef-rs: https://crates.io/crates/cef
- adblock-rust: https://github.com/brave/adblock-rust
- MCP Rust-SDK: https://github.com/modelcontextprotocol/rust-sdk
- iOS-Engine-Regeln: https://open-web-advocacy.org/blog/apples-browser-engine-ban-persists-even-under-the-dma/

### Nachrecherche Erweiterungen, Passwörter, WebViews
- WKWebExtension ab macOS 15.4 / iOS 18.4: https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
- Orion (Kagi): https://orionbrowser.com/
- WebView2-Erweiterungen: https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2profile.addbrowserextensionasync
- GeckoView-Erweiterungen: https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/WebExtensionController.html
- GNOME Web, fehlendes webRequest: https://gitlab.gnome.org/GNOME/epiphany/-/work_items/1819
- Apple, alternative Engines und Freigaben: https://developer.apple.com/support/alternative-browser-engines/
- Regelgrenze Content-Blocker (Apple-Forum, 2023): https://developer.apple.com/forums/thread/734111
- wry, eingebettete WebViews: https://docs.rs/wry/latest/wry/struct.WebViewBuilder.html

Hinweis: Die Schlussfolgerung in Abschnitt 2 stammt aus der ersten Fassung (Agenten-Nische
zuerst). Nach den Rückfragen gilt die Ausrichtung in `PLAN.md`: zuerst ein schneller,
sauberer Browser, KI als Schicht obendrauf.
