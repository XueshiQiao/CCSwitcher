<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch%20✓-blue" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
</p>

# CCSwitcher

CCSwitcher ist eine leichtgewichtige, reine Menüleisten-Anwendung für macOS, die Entwicklern hilft, nahtlos zwischen mehreren Claude Code Konten zu wechseln und diese zu verwalten. Die App überwacht die API-Nutzung, handhabt Token-Aktualisierungen elegant im Hintergrund und umgeht gängige Einschränkungen von macOS-Menüleisten-Apps.

## Funktionen

- **Multi-Account-Verwaltung**: Einfaches Hinzufügen und Wechseln zwischen verschiedenen Claude Code Konten mit einem einzigen Klick aus der macOS-Menüleiste.
- **Nutzungs-Dashboard**: Echtzeit-Überwachung Ihrer Claude API-Nutzungslimits (Sitzung und wöchentlich) direkt im Dropdown der Menüleiste.
- **Desktop-Widgets**: Native macOS Desktop-Widgets in kleiner, mittlerer und großer Größe, die Kontonutzung, Kosten und Aktivitätsstatistiken anzeigen. Enthält eine Ringdiagramm-Variante zur schnellen Nutzungsübersicht.
- **Dunkelmodus**: Vollständige Unterstützung für hellen und dunklen Modus mit adaptiven Farben, die sich automatisch an das Systemerscheinungsbild anpassen.
- **Internationalisierung**: Verfügbar in English, 简体中文 (Chinesisch), 日本語 (Japanisch), Deutsch und Français (Französisch).
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

https://github.com/XueshiQiao/CCSwitcher/raw/main/assets/CCSwitcher-screen-high-quality-1.1.0.mp4

## Zentrale Funktionen & Architektur

Diese Anwendung verwendet mehrere spezifische Architekturstrategien, von denen einige speziell auf ihren Betrieb zugeschnitten sind und andere von der Open-Source-Community inspiriert wurden.

### 1. Minimalistischer Anmeldevorgang (Native `Pipe`-Abfangung)

Im Gegensatz zu anderen Werkzeugen, die komplexe Pseudoterminals (PTY) aufbauen, um CLI-Anmeldezustände zu verarbeiten, verwendet CCSwitcher einen minimalistischen Ansatz zum Hinzufügen neuer Konten:
- Wir setzen auf nativen `Process` und standardmäßige `Pipe()`-Umleitung.
- Wenn `claude auth login` im Hintergrund ausgeführt wird, ist die Claude CLI intelligent genug, eine nicht-interaktive Umgebung zu erkennen und startet automatisch den Standard-Browser des Systems, um den OAuth-Ablauf zu verarbeiten.
- Sobald der Benutzer im Browser autorisiert hat, beendet sich der CLI-Hintergrundprozess auf natürliche Weise mit einem Erfolgs-Exit-Code (0), sodass unsere App ihren Ablauf fortsetzen und die neu generierten Keychain-Anmeldedaten erfassen kann, ohne dass der Benutzer jemals eine Terminal-Anwendung öffnen muss.

### 2. Delegierte Token-Aktualisierung (Inspiriert von CodexBar)

Claudes OAuth-Access-Tokens haben eine sehr kurze Lebensdauer (typischerweise 1-2 Stunden) und der Aktualisierungs-Endpunkt wird durch die internen Client-Signaturen der Claude CLI und Cloudflare geschützt. Um dieses Problem zu lösen, verwenden wir ein **Delegierte Aktualisierung**-Muster, inspiriert von der hervorragenden Arbeit in [CodexBar](https://github.com/lucas-clemente/codexbar):
- Anstatt dass die App versucht, den Token manuell über HTTP-Anfragen zu aktualisieren, lauschen wir auf `HTTP 401: token_expired`-Fehler von der Anthropic Usage API.
- Wenn ein 401-Fehler abgefangen wird, startet CCSwitcher sofort einen stillen Hintergrundprozess, der `claude auth status` ausführt.
- Dieser einfache schreibgeschützte Befehl zwingt die offizielle Claude Node.js CLI aufzuwachen, zu erkennen, dass der Token abgelaufen ist, und sicher einen neuen Token mit ihrer eigenen internen Logik auszuhandeln.
- Die offizielle CLI schreibt den aktualisierten Token zurück in den macOS Keychain. CCSwitcher liest daraufhin sofort den Keychain erneut aus und wiederholt die Nutzungsabfrage erfolgreich – für eine 100% nahtlose Token-Aktualisierung ohne jegliche Interaktion.

### 3. Experimenteller Security CLI Keychain-Reader (Inspiriert von CodexBar)

Das Auslesen des macOS Keychain über das native `Security.framework` (`SecItemCopyMatching`) aus einer Menüleisten-Hintergrund-App löst häufig aggressive und blockierende System-UI-Dialoge aus („CCSwitcher möchte auf Ihren Schlüsselbund zugreifen").
- Um diese UX-Hürde zu umgehen, haben wir erneut eine Strategie von **CodexBar** adaptiert:
- Wir führen das in macOS integrierte Kommandozeilenwerkzeug aus: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.
- Wenn macOS den Benutzer beim *ersten Mal* um Zugriff bittet, kann der Benutzer auf **„Immer erlauben"** klicken. Da die Anfrage von einer zentralen System-Binary (`/usr/bin/security`) und nicht von unserer signierten App-Binary kommt, merkt sich das System diese Genehmigung dauerhaft.
- Nachfolgende Hintergrund-Abfrageoperationen sind vollständig geräuschlos, wodurch Dialog-Fluten eliminiert werden.

### 4. SwiftUI `Settings`-Fenster Lifecycle-Keepalive für `LSUIElement` (Inspiriert von CodexBar)

Da CCSwitcher eine reine Menüleisten-App ist (`LSUIElement = true` in `Info.plist`), weigert sich SwiftUI, das native `Settings { ... }`-Fenster anzuzeigen. Dies ist ein bekannter macOS-Bug, bei dem SwiftUI davon ausgeht, dass die App keine aktiven interaktiven Szenen hat, an die das Einstellungsfenster angehängt werden kann.
- Wir haben CodexBars **Lifecycle-Keepalive**-Workaround implementiert.
- Beim Start erstellt die App eine `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
- Die `HiddenWindowView` fängt das zugrundeliegende `NSWindow` ab und macht es zu einem 1x1-Pixel großen, vollständig transparenten, klickdurchlässigen Fenster, das außerhalb des Bildschirms bei `x: -5000, y: -5000` positioniert ist.
- Da dieses „Geisterfenster" existiert, wird SwiftUI dazu gebracht zu glauben, die App hätte eine aktive Szene. Wenn der Benutzer auf das Zahnrad-Symbol klickt, senden wir eine `Notification`, die das Geisterfenster auffängt, um `@Environment(\.openSettings)` auszulösen – was zu einem einwandfrei funktionierenden nativen Einstellungsfenster führt.
