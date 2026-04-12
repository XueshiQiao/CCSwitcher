<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語%20✓-blue" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
</p>

# CCSwitcher

CCSwitcherは、開発者が複数のClaude Codeアカウントをシームレスに管理・切り替えできるように設計された、軽量なmacOSメニューバー専用アプリケーションです。API使用状況の監視、バックグラウンドでのトークン更新の適切な処理、macOSメニューバーアプリにおける一般的な制限の回避を行います。

## 機能

- **マルチアカウント管理**: macOSメニューバーからワンクリックで、複数のClaude Codeアカウントを簡単に追加・切り替えできます。
- **使用状況ダッシュボード**: Claude APIの使用制限（セッション単位・週単位）をメニューバーのドロップダウンからリアルタイムで監視できます。
- **デスクトップウィジェット**: macOSネイティブのデスクトップウィジェットで、小・中・大の3サイズに対応。アカウントの使用状況、コスト、アクティビティ統計を表示します。一目で使用状況を把握できるサークルリングバリアントも含まれています。
- **ダークモード**：ライトモードとダークモードに完全対応。システムの外観設定に合わせてカラーが自動的に切り替わります。
- **多言語対応**：English、简体中文、日本語、Deutsch、Français の5言語に対応しています。
- **プライバシー重視のUI**: スクリーンショットや画面収録時に、メールアドレスやアカウント名を自動的に難読化して個人情報を保護します。
- **ゼロインタラクショントークン更新**: ClaudeのOAuthトークンの期限切れを検知し、バックグラウンドで公式CLIに更新処理を委譲してインテリジェントに処理します。
- **シームレスなログインフロー**: ターミナルを一切開くことなく新しいアカウントを追加できます。アプリがバックグラウンドでCLIを起動し、ブラウザのOAuthループを自動処理します。
- **システムネイティブなUX**: 完全に機能する設定ウィンドウを備えた、ファーストクラスのmacOSメニューバーユーティリティと同じ動作をする、クリーンでネイティブなSwiftUIインターフェースです。

## スクリーンショット

<p align="center">
  <img src="assets/CCSwitcher-light.png" alt="CCSwitcher — Light Theme" width="900" /><br/>
  <em>ライトテーマ</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-dark.png" alt="CCSwitcher — Dark Theme" width="900" /><br/>
  <em>ダークテーマ</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-widgets.png" alt="CCSwitcher — Desktop Widget" width="900" /><br/>
  <em>デスクトップウィジェット</em>
</p>

## デモ

https://github.com/XueshiQiao/CCSwitcher/raw/main/assets/CCSwitcher-screen-high-quality-1.1.0.mp4

## 主要機能とアーキテクチャ

このアプリケーションは、いくつかの特殊なアーキテクチャ戦略を採用しています。独自に最適化されたものもあれば、オープンソースコミュニティからインスピレーションを得たものもあります。

### 1. ミニマリストなログインフロー（ネイティブ `Pipe` インターセプション）

CLIのログイン状態を処理するために複雑な疑似端末（PTY）を構築する他のツールとは異なり、CCSwitcherはミニマリストなアプローチで新しいアカウントを追加します：
- ネイティブの `Process` と標準の `Pipe()` リダイレクションに依存しています。
- `claude auth login` がバックグラウンドでサイレント実行されると、Claude CLIは非インタラクティブ環境を検知し、OAuthループを処理するためにシステムのデフォルトブラウザを自動的に起動します。
- ユーザーがブラウザで認可を行うと、バックグラウンドのCLIプロセスは成功終了コード（0）で自然に終了します。これにより、アプリはフローを再開し、ユーザーにターミナルアプリケーションを開かせることなく、新しく生成されたキーチェーン認証情報をキャプチャできます。

### 2. 委譲型トークン更新（CodexBarにインスパイア）

ClaudeのOAuthアクセストークンは非常に短い有効期間（通常1〜2時間）を持ち、更新エンドポイントはClaude CLIの内部クライアント署名とCloudflareによって保護されています。この問題を解決するために、[CodexBar](https://github.com/lucas-clemente/codexbar)の優れた成果にインスパイアされた**委譲型更新**パターンを使用しています：
- アプリがHTTPリクエストでトークンを手動更新する代わりに、Anthropic Usage APIからの `HTTP 401: token_expired` エラーを監視します。
- 401を検知すると、CCSwitcherは即座に `claude auth status` を実行するサイレントバックグラウンドプロセスを起動します。
- このシンプルな読み取り専用コマンドにより、公式のClaude Node.js CLIが起動し、トークンの期限切れを認識して、自身の内部ロジックを使用して安全に新しいトークンをネゴシエーションします。
- 公式CLIは更新されたトークンをmacOS Keychainに書き戻します。CCSwitcherは即座にKeychainを再読み取りし、使用状況の取得を正常にリトライすることで、100%シームレスなゼロインタラクショントークン更新を実現しています。

### 3. 実験的なSecurity CLIキーチェーンリーダー（CodexBarにインスパイア）

バックグラウンドのメニューバーアプリからネイティブの `Security.framework`（`SecItemCopyMatching`）を介してmacOS Keychainを読み取ると、攻撃的でブロッキングなシステムUIプロンプト（「CCSwitcherがキーチェーンにアクセスしようとしています」）が頻繁にトリガーされます。
- このUXの障壁を回避するために、再び**CodexBar**の戦略を採用しました：
- macOS組み込みのコマンドラインツールを実行します：`/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`。
- macOSが*初回*のアクセスに対してユーザーにプロンプトを表示した際、ユーザーは**「常に許可」**をクリックできます。リクエストがアプリの署名バイナリではなく、コアシステムバイナリ（`/usr/bin/security`）から発信されるため、システムはこの許可を永続的に記憶します。
- 以降のバックグラウンドポーリング操作は完全にサイレントとなり、プロンプトの連続表示が解消されます。

### 4. `LSUIElement`用のSwiftUI `Settings`ウィンドウライフサイクルキープアライブ（CodexBarにインスパイア）

CCSwitcherは純粋なメニューバーアプリ（`Info.plist`で `LSUIElement = true`）であるため、SwiftUIはネイティブの `Settings { ... }` ウィンドウの表示を拒否します。これは、SwiftUIが設定ウィンドウをアタッチするアクティブなインタラクティブシーンがないと判断する既知のmacOSバグです。
- CodexBarの**ライフサイクルキープアライブ**ワークアラウンドを実装しました。
- 起動時に、アプリは `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }` を作成します。
- `HiddenWindowView` は内部の `NSWindow` をインターセプトし、1x1ピクセルの完全に透明でクリックスルーなウィンドウとして、画面外の `x: -5000, y: -5000` に配置します。
- この「ゴーストウィンドウ」が存在することで、SwiftUIはアプリにアクティブなシーンがあると認識します。ユーザーが歯車アイコンをクリックすると、ゴーストウィンドウがキャッチする `Notification` を発行し、`@Environment(\.openSettings)` をトリガーすることで、完全に機能するネイティブの設定ウィンドウが表示されます。
