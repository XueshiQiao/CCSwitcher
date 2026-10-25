<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français%20✓-blue" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Español-gray" alt="Español"></a>
</p>

# CCSwitcher

CCSwitcher est une application macOS légère, fonctionnant exclusivement dans la barre de menus, conçue pour aider les développeurs à gérer et basculer entre plusieurs comptes Claude Code **sans interrompre votre workflow multi-comptes**. Le flux natif `claude auth login` est destructif : chaque changement efface les identifiants du compte précédent et force un nouveau cycle OAuth complet dans le navigateur. CCSwitcher conserve une sauvegarde par compte de tous les identifiants, échange atomiquement l'entrée du trousseau et `~/.claude.json` lors du changement, et tous les comptes restent disponibles pour un retour en un clic. Elle surveille également l'utilisation de l'API, gère gracieusement le rafraîchissement des tokens en arrière-plan et contourne les limitations courantes des applications de barre de menus macOS.

## Fonctionnalités

- **Changement de compte sans interruption** : Le natif `claude auth logout` efface les identifiants du compte actuel, et revenir en arrière nécessite un autre OAuth complet. CCSwitcher conserve une sauvegarde séparée par compte (token du trousseau + bloc `oauthAccount` de `~/.claude.json`), échange atomiquement les deux lors du changement — les identifiants de tous les comptes ajoutés restent intacts, retour en un clic, sans interrompre votre workflow. (Note : une session `claude` en cours utilisera les identifiants nouvellement échangés à son prochain appel API — c'est le comportement du CLI de Claude, pas quelque chose que CCSwitcher contrôle.)
- **Gestion multi-comptes** : Ajoutez et basculez facilement entre différents comptes Claude Code en un seul clic depuis la barre de menus macOS.
- **Tableau de bord d'utilisation** : Surveillance en temps réel de vos limites d'utilisation de l'API Claude (session 5 heures et hebdomadaire) directement dans le menu déroulant, ainsi que le coût équivalent API du jour et les statistiques d'activité (tours, minutes actives, lignes écrites, répartition par modèle).
- **Widgets de bureau** : Widgets de bureau macOS natifs en tailles petite, moyenne et grande affichant l'utilisation du compte, les coûts et les statistiques d'activité. Inclut une variante en anneau circulaire pour une surveillance rapide de l'utilisation.
- **Mise à jour automatique intégrée** : Propulsée par [Sparkle 2.x](https://sparkle-project.org/). Les nouvelles versions s'installent silencieusement et atomiquement — pas de glisser-déposer de DMG, pas de dialogues Finder.
- **Mode sombre** : Prise en charge complète des modes clair et sombre avec des couleurs adaptatives qui suivent l'apparence de votre système.
- **Internationalisation** : Disponible en English, 简体中文 (chinois), 日本語 (japonais), Deutsch (allemand), Français et Español (espagnol).
- **Interface axée sur la confidentialité** : Masque automatiquement les adresses e-mail et les noms de compte dans les captures d'écran ou les enregistrements d'écran pour protéger votre identité.
- **Rafraîchissement de token sans interaction** : Gère intelligemment l'expiration des tokens OAuth de Claude en déléguant le processus de rafraîchissement au CLI officiel en arrière-plan.
- **Flux de connexion transparent** : Ajoutez de nouveaux comptes sans jamais ouvrir un terminal. L'application invoque silencieusement le CLI et gère la boucle OAuth du navigateur pour vous.
- **Expérience native** : Une interface SwiftUI propre et native qui se comporte exactement comme un utilitaire de barre de menus macOS de premier ordre, avec une fenêtre de réglages entièrement fonctionnelle.

## Captures d'écran

<p align="center">
  <img src="assets/CCSwitcher-light.png" alt="CCSwitcher — Light Theme" width="900" /><br/>
  <em>Thème clair</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-dark.png" alt="CCSwitcher — Dark Theme" width="900" /><br/>
  <em>Thème sombre</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-widgets.png" alt="CCSwitcher — Desktop Widget" width="900" /><br/>
  <em>Widget de bureau</em>
</p>

## Démonstration

<p align="center">
  <video src="https://github.com/user-attachments/assets/ca37eaae-e8d8-4557-995e-bc154442c833" width="864" autoplay loop muted playsinline />
</p>

## Fonctionnalités clés et architecture

CCSwitcher utilise plusieurs stratégies architecturales spécifiques, certaines spécialement adaptées à son fonctionnement, d'autres inspirées par la communauté open-source (notamment [CodexBar](https://github.com/steipete/CodexBar)).

### 1. Changement de compte sans interruption

La fonctionnalité phare : **CCSwitcher conserve les identifiants de chaque compte ajouté, de sorte que le changement n'interrompt jamais votre workflow multi-comptes.**

Le CLI natif n'a pas de commande propre « changer de compte » — `claude auth logout && claude auth login` efface l'entrée du trousseau du compte actuel et déclenche un cycle OAuth complet dans le navigateur ; revenir au compte précédent demande encore un OAuth complet. CCSwitcher prend un autre chemin :

- Chaque compte précédemment ajouté est stocké dans la sauvegarde par compte propre à CCSwitcher (`~/.ccswitcher/backups.json`), contenant le JSON du token OAuth et le bloc `oauthAccount` correspondant de `~/.claude.json`.
- Lorsque l'utilisateur choisit un autre compte, CCSwitcher écrit atomiquement (a) le token du compte cible dans l'entrée du trousseau macOS `Claude Code-credentials`, et (b) écrase le bloc `oauthAccount` dans `~/.claude.json`. Les deux écritures passent par les API de fichier de Foundation — aucun effet secondaire destructif de logout/login.
- Résultat : les identifiants de chaque compte ajouté restent intacts dans la sauvegarde, disponibles immédiatement pour un retour en un clic sans nouvelle OAuth. Les nouveaux appels `claude` utilisent immédiatement le compte nouvellement sélectionné.

**À propos des sessions en cours** : CCSwitcher échange uniquement les identifiants sur disque ; il ne communique avec aucun processus `claude` en cours d'exécution. Si vous changez de compte au milieu d'une session `claude` interactive, le prochain appel API de cette session utilisera les identifiants nouvellement échangés — c'est le comportement du CLI de Claude (qui relit le trousseau à chaque appel), pas quelque chose que CCSwitcher contrôle. Terminez une session en cours avant de basculer si vous voulez qu'elle se termine sur le compte d'origine.

### 2. Flux de connexion sans terminal (`Process` + `Pipe` natifs)

Contrairement à d'autres outils qui construisent des pseudoterminaux (PTY) complexes pour gérer les états de connexion CLI, CCSwitcher utilise une approche minimaliste pour ajouter de nouveaux comptes :

- Nous nous appuyons sur `Process` natif et la redirection standard de `Pipe()`.
- Lorsque `claude auth login` est exécuté silencieusement en arrière-plan, le CLI de Claude détecte l'environnement non interactif et lance automatiquement le navigateur par défaut du système pour la boucle OAuth.
- Une fois que l'utilisateur autorise dans le navigateur, le processus CLI en arrière-plan se termine avec le code de sortie 0. CCSwitcher capture ensuite les nouveaux identifiants du trousseau et le bloc `oauthAccount` — l'utilisateur n'ouvre jamais de terminal.

### 3. Rafraîchissement de token délégué (Un chemin différent de CodexBar)

Les tokens d'accès OAuth de Claude ont une durée de vie courte (~8 heures) et le point de terminaison de rafraîchissement est protégé par les signatures client internes du CLI de Claude et Cloudflare. Les applications tierces qui veulent un rafraîchissement automatique silencieux ont deux voies, et CCSwitcher et [CodexBar](https://github.com/steipete/CodexBar) adoptent ici des approches **fondamentalement différentes** :

- **L'approche de CodexBar** : POST direct vers le point de terminaison OAuth non public d'Anthropic (`https://platform.claude.com/v1/oauth/token`) avec un `client_id` codé en dur (`9d1c250a-…`, extrait du binaire du CLI de Claude) plus le `refresh_token` du trousseau, puis parse la réponse et écrit les nouveaux tokens lui-même. Avantages : pas de sous-processus, rapide. Inconvénients : ce point de terminaison et ce client_id **ne sont pas** officiellement documentés par Anthropic — s'ils font tourner le client_id, changent le point de terminaison ou ajoutent une attestation client, le rafraîchissement échouera silencieusement jusqu'à la prochaine mise à jour de l'application.
- **L'approche de CCSwitcher** : écoute des `HTTP 401: token_expired` de l'API Usage d'Anthropic ; lorsque détecté, lance un `claude auth status` silencieux en arrière-plan — une commande en lecture seule — qui laisse le CLI officiel de Claude utiliser **sa propre logique de rafraîchissement maintenue par Anthropic** pour obtenir un nouveau token et l'écrire dans le trousseau. CCSwitcher relit le trousseau et relance la récupération des données d'utilisation.

Nous avons délibérément choisi la seconde, échangeant un petit surcoût de sous-processus par rafraîchissement contre deux vrais gains :

1. **Plus sûr** : le rafraîchissement passe par le mécanisme d'authentification du CLI officiel d'Anthropic. CCSwitcher n'a jamais à détenir ou rejouer leur `client_id` interne. Si Anthropic ajoute des vérifications côté client plus strictes (par exemple, attestation binaire), nous en héritons automatiquement sans mise à jour d'application.
2. **Pérenne** : point de terminaison, client_id, format de token — rien de tout cela ne nous incombe à maintenir. Les mises à jour du CLI apportent automatiquement la nouvelle logique de rafraîchissement.

Le résultat visible par l'utilisateur est le même que celui que voient les utilisateurs de CodexBar : transparent, sans interaction. La différence est **qui est chargé de suivre la surface OAuth privée d'Anthropic** — CodexBar s'en occupe elle-même (plus rapide, plus risqué) ; CCSwitcher délègue au CLI officiel (petit coût de sous-processus, plus sûr).

### 4. Cache local de parsing JSONL (Performance)

Les résumés de coûts et les statistiques d'activité du jour sont calculés à partir des fichiers JSONL par session de Claude Code sous `~/.claude/projects/`. Le répertoire d'un utilisateur intensif peut représenter des centaines de mégaoctets répartis sur des milliers de fichiers. À l'origine, re-parser l'arbre entier toutes les 5 minutes saturait le CPU au repos ([#13](https://github.com/XueshiQiao/CCSwitcher/issues/13)).

- CCSwitcher maintient un cache de parsing persistant par fichier à `~/Library/Application Support/CCSwitcher/session-parse-cache.json`, indexé par la mtime du fichier.
- À chaque rafraîchissement, les fichiers dont la mtime n'a pas changé sont entièrement ignorés — le cache contient leurs agrégats précédemment parsés et le résultat est sommé en mémoire.
- Seuls les fichiers activement modifiés (typiquement juste votre session Claude Code actuelle) sont re-parsés. Les rafraîchissements en régime établi passent de ~5 secondes de CPU saturé à moins de 100 ms.

### 5. Lecteur de trousseau via le CLI Security

La lecture du trousseau macOS via le `Security.framework` natif (`SecItemCopyMatching`) depuis une application de barre de menus en arrière-plan déclenche parfois une invite système bloquante — « CCSwitcher souhaite accéder à votre trousseau ». Pour la contourner, CCSwitcher adopte la stratégie de CodexBar :

- Nous exécutons l'outil système `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.
- Lorsque macOS demande à l'utilisateur *la première fois*, l'utilisateur clique sur **« Toujours autoriser »**. Comme la requête vient d'un binaire système plutôt que de notre application signée, l'autorisation persiste de manière permanente.
- Les opérations d'interrogation en arrière-plan suivantes sont complètement silencieuses.

**À propos des entrées de trousseau de sauvegarde propres à CCSwitcher** : le magasin de sauvegarde par compte (`me.xueshi.ccswitcher.backups`) est une entrée de trousseau que CCSwitcher crée et possède, il n'y a donc pas d'invite cross-vendor à éviter. Nous le lisons/écrivons via le `Security.framework` natif (`SecItemCopyMatching` / `SecItemAdd`) — pas de sous-processus, pas d'invite. En résumé : **l'approche par sous-processus `/usr/bin/security` est réservée spécifiquement à la lecture cross-vendor de l'entrée de trousseau de Claude Code ; tout le reste utilise l'API native la plus directe.**

### 6. App Group préfixé par le Team ID (Pas d'invite « Accéder aux données d'autres apps »)

macOS 15 Sequoia a silencieusement changé les règles pour les conteneurs d'App Group : toute application non distribuée via le Mac App Store, non TestFlight, dont l'ID d'App Group ne commence PAS par le Team ID du développeur déclenche une invite TCC « Gestion d'app » à chaque lancement (et à nouveau après chaque mise à jour automatique qui change le cdhash du binaire). Pour éviter cela, l'App Group de CCSwitcher est identifié comme `584KQTRF3B.me.xueshi.ccswitcher` — la forme préfixée par le Team ID, que macOS autorise automatiquement pour les apps signées Developer-ID sans profil de provisioning. Voir [#14](https://github.com/XueshiQiao/CCSwitcher/issues/14) pour l'enquête complète.

### 7. Maintien en vie du cycle de vie de la fenêtre `Settings` SwiftUI pour `LSUIElement`

Parce que CCSwitcher est une application exclusivement de barre de menus (`LSUIElement = true`), SwiftUI refuse de présenter la fenêtre native `Settings { … }` — une particularité connue de macOS où SwiftUI suppose que l'application n'a aucune scène active à laquelle rattacher Settings. CCSwitcher implémente la solution de contournement **Lifecycle Keepalive** de CodexBar :

- Au lancement, l'application crée un `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
- La `HiddenWindowView` intercepte sa `NSWindow` sous-jacente et en fait une fenêtre de 1×1 pixel, complètement transparente, traversable par les clics, positionnée hors écran à `(-5000, -5000)`.
- Parce que cette « fenêtre fantôme » existe, SwiftUI est trompé et croit que l'application a une scène active. Lorsque l'utilisateur clique sur l'icône d'engrenage, nous publions une `Notification` que la fenêtre fantôme intercepte pour déclencher `@Environment(\.openSettings)`, ce qui produit une fenêtre de réglages native parfaitement fonctionnelle.
