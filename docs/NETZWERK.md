# Eigene Netzwerk-Verbindungen von NeuralBrowser

Regel 7 aus `docs/SECURITY.md`: Jede Verbindung, die die App von sich aus aufbaut (also nicht
die Seite, die der Nutzer öffnet), steht hier mit Grund. Keine Telemetrie, nur HTTPS.

| Ziel | Wann | Grund | Was übertragen wird | Abschaltbar |
|---|---|---|---|---|
| `https://easylist.to/easylist/easylist.txt`, `…/easyprivacy.txt` | Erster Start, danach wenn die Listen älter als 4 Tage sind | Filterlisten für den Werbe- und Tracker-Blocker (`Shield.swift`) | Nur die Abfrage (IP-Adresse, kein Cookie, eigene kurzlebige Sitzung) | Noch nicht: der Schalter „Block Ads and Trackers“ stoppt das Blocken, nicht den Abruf (offen) |
| Favicon der geöffneten Seite | Beim Laden eines Tabs | Symbol in der Seitenleiste (`FaviconLoader.swift`) | Abfrage an die Website, die ohnehin offen ist | Nein |
| Vom Nutzer eingetragener Vaultwarden-Server | Geplant (SECURITY.md 4.7) | Anmelden, Tresor abgleichen, Einträge speichern | Siehe 4.7 | Baustein ist aus, solange kein Konto eingetragen ist |
