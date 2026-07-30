# Project Structure

## Organization Philosophy

単一モジュール (`Sources/yobirin/`) のフラット構成。ディレクトリ階層ではなく**責務ごとの1ファイル**と**import規律**で境界を表現する。

最重要の境界は「通知系」と「インストール系」の2群 (tech.md「CLIとアプリの二面性」):

- **通知系** (バンドル必須): NotifyCommand、AppDelegate / AppFlow、NotificationSession、NotificationCenterClient、SweepCommand、DoctorCommand。`UserNotifications` / `AppKit` をimportしてよいのはこの群だけ
- **インストール系** (バンドル不要): InstallCommand、UninstallCommand、ListCommand、PsCommand、CompletionCommand、Installer、IcnsWriter、DefaultIcon、ProfileDispatch、BundleEnvironment。通知APIの型に一切触れない — 素のバイナリで完走することの構造的保証なので、レビューではimport文を機械確認する
- **共有部品** (Foundation / Darwinのみ): TimeoutDuration (タイムアウト文字列→秒数の単一ソース。notifyとpsが共有)、TerminalDetection (`isatty` の唯一の呼び出し元。利用側は述語を注入で受ける)。どちらの群からも参照できる
- **例外 — doctor**: 通知許可の状態を報告するため通知系に分類するが、バンドル外でも完走する (通知APIの**呼び出し**はバンドル内であることを実行時に確認し、バンドル外では判定不能として報告する)。許可の読み取りは `getAuthorizationStatus` のみを使い、`requestAuthorization` を診断に使わない (許可ダイアログが出るため)

## Directory Patterns

### Sources/yobirin/

**Purpose**: CLI実体。責務単位のフラット配置
**Example**: サブコマンドは `<Name>Command.swift`、部品はその責務名 (`Installer.swift`, `IcnsWriter.swift`)。エントリポイントと起動ゲートは `Yobirin.swift`

### Tests/yobirinTests/

**Purpose**: XCTest。おおむね1ソースに1テストファイル (`<Type>Tests.swift`)
**Example**: `InstallerTests.swift`。実バイナリをプロセス起動する結合テストは `ProcessLaunchIntegrationTests.swift` に集約

### assets/icon/

**Purpose**: アイコン元画像 (リポジトリ用素材)。実行時は参照しない — 同梱標準アイコンは `DefaultIcon.swift` に生成済みバイト列として埋め込む (再生成手順はファイル内コメント)

### docs/ と .kiro/

**Purpose**: `docs/design-research.md` が設計・実測検証の原本。spec駆動開発の成果物は `.kiro/specs/yobirin-cli/` (requirements / design / tasks / research / manual-verification)

## Naming Conventions

- **Files**: 型名と一致するPascalCase (`ProfileDispatch.swift` に `ProfileNaming` と `ProfileDispatch` のように、密結合な型の同居は許容)
- **サブコマンド**: `<Name>Command.swift` / 型 `<Name>Command`
- **インストール規約由来の名前**: `Yobirin-<先頭大文字化したプロファイル名>.app` / `com.mjun0812.yobirin.<name>` — 導出も逆引きも `ProfileNaming` が単一ソース。他の場所で文字列組み立てをしない

## Code Organization Principles

- **依存方向**: コマンド (CLI層) → 部品 (Installer / ProfileNaming / ResultEmitter)。部品同士は疎。終了コードは `ResultEmitter` の定数を参照し、magic numberを書かない
- **注入パターン**: 副作用 (FileManager・Process実行・exec・exit・stdout/stderr) はクロージャ注入可能な `perform(...)` 静的関数に分離し、テストはfake注入 + テンポラリ領域で完結させる (実 `~/Applications` / 実 `~/.local/bin` に触れない)
- **純粋関数化**: 判定ロジック (起動ゲートの `LaunchGate.decide`、`BundleEnvironment.reExecTarget` 等) は入出力だけの純粋関数として切り出し、配線 (`@main` 側) は薄く保つ
- **コードコメントは日本語** (括弧は半角)。設計根拠はdesign.md / 実測記録はresearch.mdへの参照で示す
- **CLIの出力メッセージ・ヘルプは英語** (OSS公開向け、2026-07-28決定)。エラー・案内・完了メッセージ・abstract/helpすべてが対象。JSONのキーは従来どおり英語
- **フォーマット**: swift-format (`swift format lint --strict`)。コミット時にprekフックが実行される

---

_Document patterns, not file trees. New files following patterns shouldn't require updates_
_created: 2026-07-28 / updated: 2026-07-30 (cli-arguments-ux: 新サブコマンドの分類・共有部品・doctorの例外を反映)_
