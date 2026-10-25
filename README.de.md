<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch%20✓-blue" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Español-gray" alt="Español"></a>
</p>

# CCSwitcher

CCSwitcher ist eine leichtgewichtige, reine Menüleisten-Anwendung für macOS, die Entwicklern hilft, zwischen mehreren Claude Code Konten zu wechseln und diese zu verwalten – **ohne Ihren Multi-Account-Workflow zu unterbrechen**. Der native `claude auth login`-Ablauf ist destruktiv: jeder Wechsel löscht die Anmeldedaten des vorherigen Kontos und erzwingt einen weiteren vollständigen Browser-OAuth. CCSwitcher führt pro Konto ein eigenes Backup der Anmeldedaten, tauscht beim Wechsel den Keychain-Eintrag und `~/.claude.json` atomar aus, und alle Konten bleiben für einen Ein-Klick-Rückwechsel verfügbar. CCSwitcher überwacht außerdem die API-Nutzung, handhabt Token-Aktualisierungen elegant im Hintergrund und umgeht gängige Einschränkungen von macOS-Menüleisten-Apps.

## Funktionen

- **Unterbrechungsfreier Kontowechsel**: Das native `claude auth logout` löscht die Anmeldedaten des aktuellen Kontos, und ein Wechsel zurück erfordert einen weiteren vollständigen OAuth. CCSwitcher hält für jedes Konto ein separates Backup vor (Keychain-Token + `oauthAccount`-Block aus `~/.claude.json`), tauscht beide beim Wechsel atomar aus – die Anmeldedaten aller hinzugefügten Konten bleiben erhalten, Ein-Klick-Rückwechsel, kein Workflow-Unterbruch. (Hinweis: Eine laufende `claude`-Sitzung verwendet beim nächsten API-Aufruf die neu gewechselten Anmeldedaten – das ist Verhalten der Claude CLI, nichts was CCSwitcher steuert.)
- **Multi-Account-Verwaltung**: Einfaches Hinzufügen und Wechseln zwischen verschiedenen Claude Code Konten mit einem einzigen Klick aus der macOS-Menüleiste.
- **Nutzungs-Dashboard**: Echtzeit-Überwachung Ihrer Claude API-Nutzungslimits (5-Stunden-Sitzung und wöchentlich) direkt im Dropdown der Menüleiste, plus heutige API-äquivalente Kosten und Aktivitätsstatistiken (Runden, aktive Minuten, geschriebene Zeilen, Modellaufschlüsselung).
- **Desktop-Widgets**: Native macOS Desktop-Widgets in kleiner, mittlerer und großer Größe, die Kontonutzung, Kosten und Aktivitätsstatistiken anzeigen. Enthält eine Ringdiagramm-Variante zur schnellen Nutzungsübersicht.
- **In-App-Auto-Update**: Powered by [Sparkle 2.x](https://sparkle-project.org/). Neue Versionen installieren sich still und atomar – kein DMG-Ziehen, keine Finder-Dialoge.
- **Dunkelmodus**: Vollständige Unterstützung für hellen und dunklen Modus mit adaptiven Farben, die sich automatisch an das Systemerscheinungsbild anpassen.
- **Internationalisierung**: Verfügbar in English, 简体中文 (Chinesisch), 日本語 (Japanisch), Deutsch, Français (Französisch) und Español (Spanisch).
- **Datenschutzorientierte Oberfläche**: Verschleiert automatisch E-Mail-Adressen und Kontonamen in Screenshots oder Bildschirmaufnahmen, um Ihre Identität zu schützen.
- **Token-Aktualisierung ohne Interaktion**: Handhabt intelligent den Ablauf von Claudes OAuth-Token, indem der Aktualisierungsprozess im Hintergrund an die offizielle CLI delegiert wird.
- **Nahtloser Anmeldevorgang**: Fügen Sie neue Konten hinzu, ohne jemals ein Terminal öffnen zu müssen. Die App ruft die CLI im Hintergrund auf und übernimmt den Browser-OAuth-Ablauf für Sie.
- **Systemnativer UX**: Eine saubere, native SwiftUI-Oberfläche, die sich genau wie ein erstklassiges macOS-Menüleisten-Dienstprogramm verhält – inklusive eines voll funktionsfähigen Einstellungsfensters.

## Screenshots

<p align="center">
  <img src="assets/CCSwitcher-light.png" alt="CCSwitcher — Light Theme" width="900" /><br/>
  <em>Helles Design</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-dark.png" alt="CCSwitcher — Dark Theme" width="900" /><br/>
  <em>Dunkles Design</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-widgets.png" alt="CCSwitcher — Desktop Widget" width="900" /><br/>
  <em>Desktop-Widget</em>
</p>

## Demo

<p align="center">
  <video src="https://github.com/user-attachments/assets/ca37eaae-e8d8-4557-995e-bc154442c833" width="864" autoplay loop muted playsinline />
</p>

## Zentrale Funktionen & Architektur

CCSwitcher verwendet mehrere spezifische Architekturstrategien, einige speziell auf seinen Betrieb zugeschnitten, andere inspiriert von der Open-Source-Community (insbesondere [CodexBar](https://github.com/steipete/CodexBar)).

### 1. Unterbrechungsfreier Kontowechsel

Das Hauptfeature: **CCSwitcher bewahrt die Anmeldedaten jedes hinzugefügten Kontos, sodass das Wechseln Ihren Multi-Account-Workflow nicht unterbricht.**

Die native CLI hat keinen sauberen „Konto wechseln"-Befehl — `claude auth logout && claude auth login` löscht den Keychain-Eintrag des aktuellen Kontos und löst einen vollständigen Browser-OAuth aus; ein Wechsel zurück zum vorherigen Konto bedeutet eine weitere vollständige OAuth. CCSwitcher geht einen anderen Weg:

- Jedes zuvor hinzugefügte Konto wird in CCSwitchers eigener konto-spezifischer Backup-Datei (`~/.ccswitcher/backups.json`) gespeichert, mit dem OAuth-Token-JSON und dem passenden `oauthAccount`-Block aus `~/.claude.json`.
- Wenn der Benutzer ein anderes Konto wählt, schreibt CCSwitcher atomar (a) den Token des Zielkontos in den macOS Keychain-Eintrag `Claude Code-credentials` und (b) überschreibt den `oauthAccount`-Block in `~/.claude.json`. Beide Schreibvorgänge erfolgen über Foundation-Datei-APIs — keine destruktiven Logout/Login-Nebeneffekte.
- Ergebnis: Die Anmeldedaten jedes hinzugefügten Kontos bleiben im Backup intakt, jederzeit für Ein-Klick-Rückwechsel verfügbar, kein erneutes OAuth nötig. Neue `claude`-Aufrufe verwenden sofort das neu gewählte Konto.

**Zu laufenden Sitzungen**: CCSwitcher tauscht nur die Anmeldedaten auf der Festplatte aus; es kommuniziert mit keinem laufenden `claude`-Prozess. Wenn Sie mitten in einer interaktiven `claude`-Sitzung das Konto wechseln, verwendet diese Sitzung beim nächsten API-Aufruf die neu gewechselten Anmeldedaten — das ist Verhalten der Claude CLI (sie liest den Keychain bei jedem Aufruf neu), nicht etwas, das CCSwitcher steuert. Beenden Sie eine laufende Sitzung, bevor Sie wechseln, wenn sie auf dem ursprünglichen Konto abgeschlossen werden soll.

### 2. Terminal-freier Anmeldevorgang (Nativer `Process` + `Pipe`)

Im Gegensatz zu anderen Werkzeugen, die komplexe Pseudoterminals (PTY) aufbauen, um CLI-Anmeldezustände zu verarbeiten, verwendet CCSwitcher einen minimalistischen Ansatz zum Hinzufügen neuer Konten:

- Wir setzen auf nativen `Process` und standardmäßige `Pipe()`-Umleitung.
- Wenn `claude auth login` im Hintergrund ausgeführt wird, erkennt die Claude CLI die nicht-interaktive Umgebung und startet automatisch den Standard-Browser des Systems für den OAuth-Ablauf.
- Sobald der Benutzer im Browser autorisiert hat, beendet sich der CLI-Hintergrundprozess mit Exit-Code 0. CCSwitcher erfasst dann die neu generierten Keychain-Anmeldedaten und den `oauthAccount`-Block — der Benutzer öffnet nie ein Terminal.

### 3. Delegierte Token-Aktualisierung (Ein anderer Weg als CodexBar)

Claudes OAuth-Access-Tokens haben eine kurze Lebensdauer (~8 Stunden) und der Refresh-Endpunkt ist durch die internen Client-Signaturen der Claude CLI und Cloudflare geschützt. Drittanbieter-Apps, die stille Auto-Aktualisierung wollen, haben zwei Wege, und CCSwitcher und [CodexBar](https://github.com/steipete/CodexBar) verfolgen hier **grundlegend verschiedene** Ansätze:

- **CodexBars Ansatz**: direktes POST an Anthropics nicht-öffentlichen OAuth-Refresh-Endpunkt (`https://platform.claude.com/v1/oauth/token`) mit einer hardcodierten `client_id` (`9d1c250a-…`, aus der Claude CLI Binary extrahiert) plus dem `refresh_token` aus dem Keychain, parst dann selbst die Antwort und schreibt die neuen Tokens zurück. Vorteile: kein Subprozess, schnell. Nachteile: Dieser Endpunkt und die client_id sind **nicht** offiziell von Anthropic dokumentiert — wenn sie die client_id rotieren, den Endpunkt ändern oder Client-Attestierung hinzufügen, bricht die Aktualisierung still bis zum nächsten App-Update.
- **CCSwitchers Ansatz**: lauscht auf `HTTP 401: token_expired` von der Anthropic Usage API; bei Auftreten startet er einen stillen Hintergrund-`claude auth status` — einen schreibgeschützten Befehl — der die offizielle Claude CLI ihre **eigene, von Anthropic gepflegte** Refresh-Logik verwenden lässt, um einen neuen Token zu holen und ihn in den Keychain zurückzuschreiben. CCSwitcher liest dann den Keychain neu und wiederholt die Nutzungsabfrage.

Wir haben uns bewusst für letzteres entschieden — wir tauschen einen winzigen Subprozess-Overhead pro Refresh gegen zwei echte Gewinne:

1. **Sicherer**: Die Aktualisierung läuft über Anthropics eigene CLI-Auth-Mechanik. CCSwitcher muss ihre interne `client_id` nie halten oder erneut senden. Wenn Anthropic strengere Client-seitige Prüfungen hinzufügt (z. B. Binär-Attestierung), erben wir sie automatisch ohne App-Update.
2. **Zukunftssicher**: Endpunkt, client_id, Token-Format — nichts davon müssen wir pflegen. CLI-Upgrades bringen automatisch neue Refresh-Logik mit.

Das vom Benutzer sichtbare Ergebnis ist dasselbe, das CodexBar-Benutzer sehen: nahtlos, ohne Interaktion. Der Unterschied liegt darin, **wer dafür verantwortlich ist, Anthropics private OAuth-Oberfläche im Auge zu behalten** — CodexBar übernimmt das selbst (schneller, riskanter); CCSwitcher delegiert an die offizielle CLI (kleiner Subprozess-Aufwand, sicherer).

### 4. Lokaler JSONL-Parse-Cache (Performance)

Kostenübersichten und Heutige-Aktivität-Statistiken werden aus Claude Codes pro-Sitzung-JSONL-Dateien unter `~/.claude/projects/` berechnet. Das Verzeichnis eines Power-Users kann hunderte Megabyte über tausende Dateien umfassen. Ursprünglich verbrauchte das alle 5 Minuten erfolgende Reparsen des gesamten Baums im Leerlauf die CPU vollständig ([#13](https://github.com/XueshiQiao/CCSwitcher/issues/13)).

- CCSwitcher pflegt einen persistenten pro-Datei-Parse-Cache unter `~/Library/Application Support/CCSwitcher/session-parse-cache.json`, mit der Datei-mtime als Schlüssel.
- Bei jedem Refresh werden Dateien mit unveränderter mtime komplett übersprungen — der Cache enthält ihre zuvor geparsten Aggregate, und das Ergebnis wird im Speicher summiert.
- Nur die aktiv modifizierten Dateien (typischerweise nur Ihre aktuelle Claude Code Sitzung) werden neu geparst. Steady-State-Refreshes fallen von ~5 Sekunden CPU-Sättigung auf unter 100 ms.

### 5. Security-CLI Keychain-Reader

Das Auslesen des macOS Keychain über das native `Security.framework` (`SecItemCopyMatching`) aus einer Menüleisten-Hintergrund-App löst manchmal einen blockierenden System-UI-Dialog aus — „CCSwitcher möchte auf Ihren Schlüsselbund zugreifen". Um das zu umgehen, übernimmt CCSwitcher CodexBars Strategie:

- Wir führen das system-mitgelieferte Tool `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` aus.
- Wenn macOS den Benutzer *beim ersten Mal* fragt, klickt der Benutzer auf **„Immer erlauben"**. Da die Anfrage von einer System-Binary und nicht von unserer signierten App kommt, bleibt die Genehmigung dauerhaft erhalten.
- Nachfolgende Hintergrund-Polling-Operationen sind völlig still.

**Zu CCSwitchers eigenen Backup-Keychain-Einträgen**: Der pro-Konto Backup-Store (`me.xueshi.ccswitcher.backups`) ist ein Keychain-Eintrag, den CCSwitcher erstellt und besitzt, also gibt es keine cross-vendor-Dialoge zu umgehen. Wir lesen/schreiben ihn über das native `Security.framework` (`SecItemCopyMatching` / `SecItemAdd`) — kein Subprozess, kein Dialog. Kurz: **Der `/usr/bin/security`-Subprozess-Ansatz ist speziell für das cross-vendor-Lesen von Claude Codes Keychain-Eintrag reserviert; alles andere verwendet die direkteste native API.**

### 6. Team-ID-präfixierte App Group (Kein „Auf Daten anderer Apps zugreifen"-Dialog)

macOS 15 Sequoia änderte still die Regeln für App-Group-Container: jede nicht-Mac-App-Store-, nicht-TestFlight-App, deren App-Group-ID NICHT mit der Entwickler-Team-ID beginnt, löst bei jedem Start einen TCC „App-Verwaltung"-Dialog aus (und erneut nach jedem Auto-Update, das den cdhash der Binary ändert). Um das zu vermeiden, ist CCSwitchers App Group als `584KQTRF3B.me.xueshi.ccswitcher` identifiziert — die Team-ID-präfixierte Form, die macOS für Developer-ID-signierte Apps ohne Provisioning-Profile automatisch autorisiert. Siehe [#14](https://github.com/XueshiQiao/CCSwitcher/issues/14) für die vollständige Untersuchung.

### 7. SwiftUI `Settings`-Fenster Lifecycle-Keepalive für `LSUIElement`

Da CCSwitcher eine reine Menüleisten-App ist (`LSUIElement = true`), weigert sich SwiftUI, das native `Settings { … }`-Fenster anzuzeigen — ein bekannter macOS-Eigenheit, bei der SwiftUI davon ausgeht, dass die App keine aktive Szene hat, an die Settings angehängt werden kann. CCSwitcher implementiert CodexBars **Lifecycle-Keepalive**-Workaround:

- Beim Start erstellt die App eine `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
- Die `HiddenWindowView` fängt das zugrundeliegende `NSWindow` ab und macht es zu einem 1×1-Pixel großen, vollständig transparenten, klickdurchlässigen Fenster, das außerhalb des Bildschirms bei `(-5000, -5000)` positioniert ist.
- Da dieses „Geisterfenster" existiert, wird SwiftUI dazu gebracht zu glauben, die App hätte eine aktive Szene. Wenn der Benutzer auf das Zahnrad-Symbol klickt, senden wir eine `Notification`, die das Geisterfenster auffängt, um `@Environment(\.openSettings)` auszulösen — was zu einem einwandfrei funktionierenden nativen Einstellungsfenster führt.
