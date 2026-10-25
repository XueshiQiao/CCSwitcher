<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語%20✓-blue" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Español-gray" alt="Español"></a>
</p>

# CCSwitcher

CCSwitcherは、開発者が複数のClaude Codeアカウントを**マルチアカウントワークフローを中断することなく**管理・切り替えできるように設計された、軽量なmacOSメニューバー専用アプリケーションです。ネイティブの `claude auth login` フローは破壊的です——切り替えるたびに前のアカウントの認証情報を消去し、ブラウザでのフル OAuth をもう一度強制します。CCSwitcher は各アカウントごとに認証情報のバックアップを保持し、切り替え時にキーチェーンエントリと `~/.claude.json` を原子的に入れ替えるため、すべてのアカウントがワンクリックで切り戻し可能なまま残ります。CCSwitcherはAPI使用状況も監視し、バックグラウンドでのトークン更新を適切に処理し、macOSメニューバーアプリにおける一般的な制限を回避します。

## 機能

- **中断のないアカウント切り替え**: ネイティブの `claude auth logout` は現在のアカウントの認証情報を消し、切り戻すには再び完全な OAuth が必要です。CCSwitcher は各アカウントの独立したバックアップ（キーチェーンの token + `~/.claude.json` の `oauthAccount` ブロック）を保持し、切り替え時に両方を原子的に入れ替えます——追加された全アカウントの認証情報はそのまま残り、ワンクリックで切り戻し可能、ワークフローを中断しません。（注：進行中の `claude` セッションは次の API 呼び出しで新しく切り替えられた認証情報を使用します——これは Claude CLI 自身の動作であり、CCSwitcher が制御するものではありません。）
- **マルチアカウント管理**: macOSメニューバーからワンクリックで、複数のClaude Codeアカウントを簡単に追加・切り替えできます。
- **使用状況ダッシュボード**: Claude APIの使用制限（5時間セッションと週単位）をメニューバーのドロップダウンからリアルタイムで監視。当日のAPI相当コストとアクティビティ統計（ターン、アクティブ分、書き込まれた行数、モデル別内訳）も表示します。
- **デスクトップウィジェット**: macOSネイティブのデスクトップウィジェットで、小・中・大の3サイズに対応。アカウントの使用状況、コスト、アクティビティ統計を表示します。一目で使用状況を把握できるサークルリングバリアントも含まれています。
- **アプリ内自動更新**: [Sparkle 2.x](https://sparkle-project.org/) によって駆動。新しいバージョンはサイレントかつ原子的にインストール——DMGのドラッグもFinderダイアログも不要です。
- **ダークモード**：ライトモードとダークモードに完全対応。システムの外観設定に合わせてカラーが自動的に切り替わります。
- **多言語対応**：English、简体中文、日本語、Deutsch、Français、Español の6言語に対応しています。
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

<p align="center">
  <video src="https://github.com/user-attachments/assets/ca37eaae-e8d8-4557-995e-bc154442c833" width="864" autoplay loop muted playsinline />
</p>

## 主要機能とアーキテクチャ

CCSwitcherは、独自に最適化された戦略と、オープンソースコミュニティ（特に [CodexBar](https://github.com/steipete/CodexBar)）からインスピレーションを得た戦略の両方を採用しています。

### 1. 中断のないアカウント切り替え

CCSwitcherの目玉機能：**追加された全アカウントの認証情報を保持することで、アカウント切り替えがマルチアカウントワークフローを中断しません。**

ネイティブ CLI には「アカウントを切り替える」という綺麗なコマンドがありません——`claude auth logout && claude auth login` は現在のアカウントのキーチェーンエントリを消去してブラウザで完全な OAuth フローを起動し、前のアカウントに戻すには再び完全なログインが必要です。CCSwitcher は別のアプローチを取ります：

- 過去に追加されたアカウントはそれぞれ、CCSwitcher 独自のアカウント単位のバックアップ（`~/.ccswitcher/backups.json`）に保存され、OAuth トークン JSON と `~/.claude.json` の対応する `oauthAccount` ブロックが含まれます。
- ユーザーが別のアカウントを選ぶと、CCSwitcher は原子的に (a) ターゲットアカウントのトークンを macOS キーチェーンエントリ `Claude Code-credentials` に書き込み、(b) `~/.claude.json` の `oauthAccount` ブロックを上書きします。両方の書き込みは Foundation のファイル API で行われ、logout/login の破壊的な副作用はありません。
- 結果：追加された全アカウントの認証情報はバックアップに保持され、ワンクリックで切り戻し可能、OAuth のやり直しは不要です。新しい `claude` の呼び出しはすぐに新しく選択されたアカウントを使用します。

**進行中のセッションについて**：CCSwitcher はディスク上の認証情報を原子的に入れ替えるだけで、実行中の `claude` プロセスとは通信しません。`claude` の対話セッションの途中でアカウントを切り替えた場合、そのセッションの次の API 呼び出しは新しく切り替えられた認証情報を使用します——これは Claude CLI の動作（呼び出しごとにキーチェーンを再読み込みする）であり、CCSwitcher が制御するものではありません。進行中のセッションを元のアカウントで完了させたい場合は、切り替える前にそのセッションを終了してください。

### 2. ターミナル不要のログインフロー（ネイティブ `Process` + `Pipe`）

CLIのログイン状態を処理するために複雑な疑似端末（PTY）を構築する他のツールとは異なり、CCSwitcherはミニマリストなアプローチで新しいアカウントを追加します：

- ネイティブの `Process` と標準の `Pipe()` リダイレクションに依存しています。
- `claude auth login` がバックグラウンドでサイレント実行されると、Claude CLIは非インタラクティブ環境を検知し、OAuthループを処理するためにシステムのデフォルトブラウザを自動的に起動します。
- ユーザーがブラウザで認可を行うと、バックグラウンドのCLIプロセスは終了コード0で終了します。CCSwitcherは新しく生成されたキーチェーン認証情報と `oauthAccount` ブロックをキャプチャします——ユーザーはターミナルを開きません。

### 3. 委譲型トークン更新（CodexBar とは別の道）

Claude の OAuth アクセストークンは短い有効期間（約 8 時間）を持ち、更新エンドポイントは Claude CLI の内部クライアント署名と Cloudflare によって保護されています。サードパーティアプリがサイレント自動更新を実現するには 2 つの道があり、CCSwitcher と [CodexBar](https://github.com/steipete/CodexBar) は**根本的に異なる**アプローチを取っています：

- **CodexBar のアプローチ**：Anthropic の非公開 OAuth 更新エンドポイント（`https://platform.claude.com/v1/oauth/token`）に、ハードコードされた `client_id`（`9d1c250a-…`、Claude CLI バイナリから抽出）とキーチェーンの `refresh_token` を一緒に直接 POST し、応答をパースして新しいトークンを自分で書き戻します。利点：サブプロセス不要、高速。欠点：このエンドポイントと client_id は Anthropic が公式に文書化していない——彼らが client_id をローテーションしたり、エンドポイントを変更したり、クライアント証明を追加した場合、次のアプリ更新まで更新が無音で壊れます。
- **CCSwitcher のアプローチ**：Anthropic Usage API からの `HTTP 401: token_expired` を監視し、検知時にサイレントバックグラウンドで `claude auth status` ——読み取り専用コマンド——を起動します。これにより公式 Claude CLI が**自身の、Anthropic がメンテナンスする**更新ロジックを使って新しいトークンを取得し、キーチェーンに書き戻します。CCSwitcher はキーチェーンを再読み取りし、使用状況の取得をリトライします。

私たちは意図的に後者を選びました。更新ごとの小さなサブプロセスのオーバーヘッドと引き換えに、2 つの実利を得ます：

1. **より安全**：更新は Anthropic 自身の CLI 認証メカニズムを通ります。CCSwitcher は彼らの内部 `client_id` を保持・再送する必要が一切ありません。Anthropic がより厳しいクライアント側チェック（例：バイナリ証明）を追加した場合、アプリ更新なしで自動的に継承されます。
2. **将来性**：エンドポイント、client_id、トークン形式——どれも私たちがメンテナンスするものではありません。CLI のアップグレードが自動的に新しい更新ロジックをもたらします。

ユーザーが目にする結果は CodexBar のユーザーが目にするものと同じです：シームレス、ゼロインタラクション。違いは**誰が Anthropic の私的な OAuth 表面についていく責任を負うか**です——CodexBar は自分でそれを担う（高速だがリスクあり）、CCSwitcher は公式 CLI に委譲する（小さなサブプロセスコスト、より安全）。

### 4. ローカルJSONLパースキャッシュ（パフォーマンス）

コストの集計と当日のアクティビティ統計は、`~/.claude/projects/` 下の各セッションのJSONLファイルから計算されます。ヘビーユーザーのこのディレクトリは数千ファイル、合計数百MBになることもあります。当初、5分ごとにツリー全体を再パースしていたためアイドル時にCPUが張り付いていました（[#13](https://github.com/XueshiQiao/CCSwitcher/issues/13)）。

- CCSwitcherは `~/Library/Application Support/CCSwitcher/session-parse-cache.json` にファイルmtimeをキーとする永続的なファイル単位のパースキャッシュを保持します。
- 各リフレッシュ時、mtimeが変わっていないファイルは完全にスキップ——キャッシュにそれらの以前のパース集計値が保持されており、メモリ内で合計するだけです。
- アクティブに変更されているファイル（通常はあなたの現在のClaude Codeセッションだけ）のみが再パースされます。定常状態のリフレッシュは約5秒のCPU飽和から100ms未満に下がります。

### 5. Security-CLIキーチェーンリーダー

バックグラウンドのメニューバーアプリからネイティブの `Security.framework`（`SecItemCopyMatching`）を介してmacOSキーチェーンを読み取ると、ブロッキングなシステムUIプロンプト——「CCSwitcherがキーチェーンにアクセスしようとしています」——が表示されることがあります。これを回避するため、CCSwitcherはCodexBarの戦略を採用します：

- システム同梱ツール `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` を実行します。
- macOSが*初回*プロンプトを表示した際、ユーザーは**「常に許可」**をクリックします。リクエストが私たちの署名アプリではなくシステムバイナリから発信されるため、許可は永続的に保持されます。
- 以降のバックグラウンドポーリングは完全にサイレントです。

**CCSwitcher 自身のバックアップキーチェーンエントリについて**：アカウントごとのバックアップストア（`me.xueshi.ccswitcher.backups`）は CCSwitcher が作成・所有するキーチェーンエントリなので、回避すべきクロスベンダープロンプトはありません。ネイティブの `Security.framework`（`SecItemCopyMatching` / `SecItemAdd`）で読み書きします——サブプロセスなし、プロンプトなし。要するに：**`/usr/bin/security` サブプロセスアプローチは Claude Code のキーチェーンエントリへのクロスベンダー読み取りのために専用に使われ、それ以外はすべて最も直接的なネイティブ API を使います。**

### 6. Team-IDプレフィックス付きApp Group（「他のAppのデータにアクセス」プロンプトの回避）

macOS 15 SequoiaはApp Groupコンテナのルールを密かに変更しました：Mac App Store以外、TestFlight以外で配布されるアプリで、App Group IDが開発者のTeam IDで始まらないものは、起動のたびにTCC「App管理」プロンプトをトリガーします（バイナリのcdhashを変える自動更新後にも再度トリガーされます）。これを避けるため、CCSwitcherのApp Group識別子は `584KQTRF3B.me.xueshi.ccswitcher` ——Team IDプレフィックス形式——です。これはprovisioning profileを持たないDeveloper-ID署名アプリに対してmacOSが自動承認します。詳細な調査は [#14](https://github.com/XueshiQiao/CCSwitcher/issues/14) を参照してください。

### 7. `LSUIElement`用のSwiftUI `Settings`ウィンドウライフサイクルキープアライブ

CCSwitcherは純粋なメニューバーアプリ（`Info.plist`で `LSUIElement = true`）であるため、SwiftUIはネイティブの `Settings { ... }` ウィンドウの表示を拒否します。これは、SwiftUIが設定ウィンドウをアタッチするアクティブなインタラクティブシーンがないと判断する既知のmacOSバグです。
- CodexBarの**ライフサイクルキープアライブ**ワークアラウンドを実装しました。
- 起動時に、アプリは `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }` を作成します。
- `HiddenWindowView` は内部の `NSWindow` をインターセプトし、1x1ピクセルの完全に透明でクリックスルーなウィンドウとして、画面外の `x: -5000, y: -5000` に配置します。
- この「ゴーストウィンドウ」が存在することで、SwiftUIはアプリにアクティブなシーンがあると認識します。ユーザーが歯車アイコンをクリックすると、ゴーストウィンドウがキャッチする `Notification` を発行し、`@Environment(\.openSettings)` をトリガーすることで、完全に機能するネイティブの設定ウィンドウが表示されます。
