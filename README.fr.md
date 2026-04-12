<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français%20✓-blue" alt="Français"></a>
</p>

# CCSwitcher

CCSwitcher est une application macOS légère, fonctionnant exclusivement dans la barre de menus, conçue pour aider les développeurs à gérer et basculer facilement entre plusieurs comptes Claude Code. Elle surveille l'utilisation de l'API, gère gracieusement le rafraîchissement des tokens en arrière-plan et contourne les limitations courantes des applications de barre de menus macOS.

## Fonctionnalités

- **Gestion multi-comptes** : Ajoutez et basculez facilement entre différents comptes Claude Code en un seul clic depuis la barre de menus macOS.
- **Tableau de bord d'utilisation** : Surveillance en temps réel de vos limites d'utilisation de l'API Claude (session et hebdomadaire) directement dans le menu déroulant de la barre de menus.
- **Widgets de bureau** : Widgets de bureau macOS natifs en tailles petite, moyenne et grande affichant l'utilisation du compte, les coûts et les statistiques d'activité. Inclut une variante en anneau circulaire pour une surveillance rapide de l'utilisation.
- **Interface axée sur la confidentialité** : Masque automatiquement les adresses e-mail et les noms de compte dans les captures d'écran ou les enregistrements d'écran pour protéger votre identité.
- **Rafraîchissement de token sans interaction** : Gère intelligemment l'expiration des tokens OAuth de Claude en déléguant le processus de rafraîchissement au CLI officiel en arrière-plan.
- **Flux de connexion transparent** : Ajoutez de nouveaux comptes sans jamais ouvrir un terminal. L'application invoque silencieusement le CLI et gère la boucle OAuth du navigateur pour vous.
- **Expérience native** : Une interface SwiftUI propre et native qui se comporte exactement comme un utilitaire de barre de menus macOS de premier ordre, avec une fenêtre de réglages entièrement fonctionnelle.

## Captures d'écran

<p align="center">
  <img src="assets/CCSwitcher-light.png" alt="CCSwitcher — Light Theme" width="600" /><br/>
  <em>Thème clair</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-dark.png" alt="CCSwitcher — Dark Theme" width="600" /><br/>
  <em>Thème sombre</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-widgets.png" alt="CCSwitcher — Desktop Widget" width="500" /><br/>
  <em>Widget de bureau</em>
</p>

## Démonstration

<video src="assets/CCSwitcher-screen-high-quality-1.1.0.mp4" controls width="600"></video>

## Fonctionnalités clés et architecture

Cette application utilise plusieurs stratégies architecturales spécifiques, certaines étant spécialement adaptées à son fonctionnement et d'autres s'inspirant de la communauté open-source.

### 1. Flux de connexion minimaliste (Interception native de `Pipe`)

Contrairement à d'autres outils qui construisent des pseudoterminaux (PTY) complexes pour gérer les états de connexion CLI, CCSwitcher utilise une approche minimaliste pour ajouter de nouveaux comptes :
- Nous nous appuyons sur `Process` natif et la redirection standard de `Pipe()`.
- Lorsque `claude auth login` est exécuté silencieusement en arrière-plan, le CLI de Claude est suffisamment intelligent pour détecter un environnement non interactif et lance automatiquement le navigateur par défaut du système pour gérer la boucle OAuth.
- Une fois que l'utilisateur autorise dans le navigateur, le processus CLI en arrière-plan se termine naturellement avec un code de sortie de succès (0), permettant à notre application de reprendre son flux et de capturer les nouveaux identifiants du trousseau sans jamais nécessiter que l'utilisateur ouvre une application de terminal.

### 2. Rafraîchissement de token délégué (Inspiré par CodexBar)

Les tokens d'accès OAuth de Claude ont une durée de vie très courte (généralement 1 à 2 heures) et le point de terminaison de rafraîchissement est protégé par les signatures client internes du CLI de Claude et Cloudflare. Pour résoudre ce problème, nous utilisons un modèle de **rafraîchissement délégué** inspiré de l'excellent travail de [CodexBar](https://github.com/lucas-clemente/codexbar) :
- Au lieu que l'application tente de rafraîchir manuellement le token via des requêtes HTTP, nous écoutons les erreurs `HTTP 401: token_expired` provenant de l'API Anthropic Usage.
- Lorsqu'une erreur 401 est interceptée, CCSwitcher lance immédiatement un processus silencieux en arrière-plan exécutant `claude auth status`.
- Cette simple commande en lecture seule force le CLI officiel Claude Node.js à se réveiller, constater que le token est expiré et négocier de manière sécurisée un nouveau token en utilisant sa propre logique interne.
- Le CLI officiel écrit le token rafraîchi dans le trousseau macOS (Keychain). CCSwitcher relit alors immédiatement le trousseau et relance avec succès la récupération des données d'utilisation, réalisant un rafraîchissement de token 100 % transparent et sans aucune interaction.

### 3. Lecteur expérimental du trousseau via le CLI Security (Inspiré par CodexBar)

La lecture du trousseau macOS (Keychain) via le `Security.framework` natif (`SecItemCopyMatching`) depuis une application de barre de menus en arrière-plan déclenche souvent des invites système agressives et bloquantes (« CCSwitcher souhaite accéder à votre trousseau »).
- Pour contourner cet obstacle d'expérience utilisateur, nous avons de nouveau adapté une stratégie de **CodexBar** :
- Nous exécutons l'outil en ligne de commande intégré à macOS : `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.
- Lorsque macOS demande à l'utilisateur l'accès pour la *première fois*, l'utilisateur peut cliquer sur **« Toujours autoriser »**. Comme la requête provient d'un binaire système central (`/usr/bin/security`) plutôt que du binaire signé de notre application, le système mémorise cette autorisation de manière permanente.
- Les opérations d'interrogation en arrière-plan suivantes sont complètement silencieuses, éliminant les rafales d'invites.

### 4. Maintien en vie du cycle de vie de la fenêtre `Settings` SwiftUI pour `LSUIElement` (Inspiré par CodexBar)

Parce que CCSwitcher est une application exclusivement de barre de menus (`LSUIElement = true` dans `Info.plist`), SwiftUI refuse de présenter la fenêtre native `Settings { ... }`. C'est un bug connu de macOS où SwiftUI suppose que l'application n'a aucune scène interactive active à laquelle rattacher la fenêtre de réglages.
- Nous avons implémenté la solution de contournement **Lifecycle Keepalive** de CodexBar.
- Au lancement, l'application crée un `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
- La `HiddenWindowView` intercepte sa `NSWindow` sous-jacente et en fait une fenêtre de 1x1 pixel, complètement transparente, traversable par les clics, positionnée hors écran à `x: -5000, y: -5000`.
- Parce que cette « fenêtre fantôme » existe, SwiftUI est trompé et croit que l'application a une scène active. Lorsque l'utilisateur clique sur l'icône d'engrenage, nous publions une `Notification` que la fenêtre fantôme intercepte pour déclencher `@Environment(\.openSettings)`, ce qui produit une fenêtre de réglages native parfaitement fonctionnelle.
