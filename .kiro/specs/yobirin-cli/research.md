# Research & Design Decisions

> `docs/design-research.md` (2026-07-26) からの移植。本ファイルは要約であり、実験の生ログ・全検証表は原本を参照。

## Summary

- **Feature**: `yobirin-cli`
- **Discovery Scope**: New Feature
- **Key Findings**:
  - 「モダンなUN APIで、通知への反応を同期的に構造化データで返す汎用CLI」は存在しない (競合分析で空席を確認)
  - `customDismissAction` による却下検知はポーリング不要で機能する (実測。yobirinの最大の技術的前提が実証された)
  - 通知アイコンの実行時差し替えは公開API・私用APIとも全滅。alerterのアイコン差し替えは `com.apple.Terminal` へのなりすましで成立していた
  - ラッパー・IPC・`open` 経由起動はすべて不要。symlinkからの直接実行で通知が出せ、結果はstdoutに同期的に返る
  - 配置場所 (`~/Applications` 等の正規の場所) が効くのは初回の通知許可取得時のみ。許可後は場所を問わず動作する

## Research Log

### 競合分析 (2026-07-26)

- **Context**: alerterのメモリリーク (48分で1.8GB、CPU 11%) を機に、乗り換え先または自作の判断が必要になった
- **Findings**:
  - [vjeantet/alerter](https://github.com/vjeantet/alerter): 機能面では本家だが、非推奨 `NSUserNotification` + 毎秒約5回のポーリングでリーク。修正PR [#65](https://github.com/vjeantet/alerter/pull/65) は4ヶ月未マージ
  - [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier): 最終release 2017年。fire-and-forgetで対話捕捉不可
  - [variadico/noti](https://github.com/variadico/noti) / [dschep/ntfy](https://github.com/dschep/ntfy): コマンド完了通知が目的で対話捕捉は非目標
  - [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications): Swift + UN APIで対話捕捉可能だが、MDM向け常駐agentでCLIワンショット用途には過剰
  - [777genius/claude-notifications-go](https://github.com/777genius/claude-notifications-go): UN APIで対話捕捉可能だが、Claude Code plugin機構専用。全面乗り換えは棄却 (Codex非対応 [#105](https://github.com/777genius/claude-notifications-go/issues/105)、SSH時のOSC 777/9通知なし、dotfilesのマルチagent一元管理と相性が悪い)。#105が解決されたら再評価する
- **Implications**: 空席を自作で埋める。terminal-notifier / alerterの停滞理由は `NSUserNotification` 廃止対応の負債なので、最初からUN APIのみを対象とし私用APIハックを採用しないことが長寿命の条件

### 参考実装

- **主参考**: claude-notifications-goの [`swift-notifier/`](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier)。「Swift Package (executableTarget) + シェルスクリプトでバンドル組み立て」構成でXcodeプロジェクトを使わない。[`scripts/build-app.sh`](https://github.com/777genius/claude-notifications-go/blob/main/swift-notifier/scripts/build-app.sh) がバンドル組み立ての答えそのもの (2アーキビルド → `lipo` → バンドル → `sips`+`iconutil` → 署名 → `open -W -n` スモークテスト)。`AppDelegate.swift` の `asyncAfter(deadline: .now() + 0.5)` による遅延exitは本設計の遅延exit値の裏付け
- **副次**: IBM/mac-ibm-notifications (UNの使い方の教科書として部分参照)、vjeantet/alerter (旧API側の教科書。CLIオプション設計・`--group`・JSON出力・PR #65)
- **構成が異なる点**: swift-notifierはGo側から起動してフォーカス制御する作りで、結果を呼び出し元へ同期返却しない。yobirinのstdout同期返却部分は参考にしない

### アイコン差し替えの回避策調査

- **Context**: UN APIでは通知アイコンは送信アプリのバンドルアイコンに固定され、通知ごとに変える公式手段がない ([Apple公式フォーラム](https://developer.apple.com/forums/thread/134147))
- **Findings** (候補と判定):
  - A. 派生バンドル生成 (notificator方式): ○ 確実、本線。公開APIのみ
  - B. `NSApp.applicationIconImage` 実行時差し替え: ✕ (実測で否定。Dock専用)
  - C. Communication Notifications (INSendMessageIntent): ✕✕ (実測で否定。ad-hoc署名でentitlementを主張するとアプリが起動不能。entitlementなしではAPIは成功するがアバター非表示)
  - D. UN私用APIハック (`UNNotificationIcon` + `content.icon`): ✕ (実測で否定。6メソッドすべてで生成・設定・配信は成功するが表示は不変。サーバ側 `allowPrivateProperties` ゲートの存在が実証された)
  - E. icns書き換え / attachment: ✕ (attachmentは右側サムネイル止まり。icnsはキャッシュが強い)
- **Implications**: アイコンはビルド時にバンドルへ焼き込む以外に手段がない。`--icon` オプションは提供しない。可変アイコンは派生バンドル (プロファイル方式) で実現する

### M2a 実機検証 (2026-07-26、macOS 26 / Darwin 25)

Swiftプロトタイプ (約180行 + `.app` バンドル + ad-hoc署名) での主要な実測結果:

- **クリック検知**: ○ / **却下検知 (`customDismissAction`)**: ○ ポーリング不要で取得できる (最大の技術的前提が実証)
- **動的category登録**: ○ `setNotificationCategories` の呼び直しで機能する
- **`/private/tmp` 配置**: ✕ バンドルがアプリとして認識されず `UNErrorDomain Code=1`。**ホーム以下配置**: ○
- **バンドルアイコン**: 新Bundle IDで初回から埋め込めば○。既存Bundle IDへの後付けは✕ (通知ソースがキャッシュされ再生成されない)
- **delegate内での即exit**: ✕ ダイアログが出る (`open` 起動時)。結果出力後1秒待ってexitで解消
- **素のMach-Oで新API**: ✕ `bundleProxyForCurrentProcess is nil` で例外死。埋め込みInfo.plistでも回避不可

### 旧API vs 新API / なりすまし検証

- **alerterのアイコン差し替えの正体**: [`BundleIdentifierHook.m`](https://github.com/vjeantet/alerter/blob/master/Sources/BundleHook/BundleIdentifierHook.m) で `NSBundle.bundleIdentifier` をswizzleし `com.apple.Terminal` を返す。通知はTerminal.appの名義で配信されており、システムアプリ扱いだから私用プロパティ `_identityImage` が採用される。ad-hoc再署名でもBundle IDパッチでも動き続けたことがこれを裏付ける (署名・Bundle IDは無関係)
- **正直な実装 (なりすましなし) の旧API**: 通知が表示すらされない
- **新APIへのなりすまし移植**: 両手法とも拒否された。swizzleは `requestAuthorization` が `Code=1` で拒否。私用 `initWithBundleIdentifier:` も配信が `Code=1` で拒否。新APIは身元を `NSBundle` ではなくLaunchServicesのbundleProxyから取得しており、コード上の細工では変えられない (なりすましの経路そのものが設計として閉じている)
- **教訓 (推論の誤りの記録)**: 「Developer ID署名が必要」「新規Bundle IDの許可が定着しない」という2つの誤推論を、「同じコードでIDだけ変える」「同じIDでコードだけ変える」の交差実験で反証・特定した
- **副産物**: Apple Developer Program加入は不要と確定 (署名は無関係だった)。加入の実利はOSS配布時のnotarizationのみ

### IPCは不要だった (前言訂正)

- **Context**: M2a当初は「symlink方式は不可、`open` 起動 + IPCが必須」と結論していたが、最初の実験で配置場所と実行方法を同時に変えてしまい、原因を実行方法に誤帰属していた
- **Findings** (切り分け直しの実測):
  - ホーム以下のバンドル内Mach-Oの直接実行: ○ 通知が配信される
  - PATH上のsymlink経由: ○ (`Bundle.main` は正しく `.app` に解決される)
  - 結果の同期取得: ○ そのプロセスのstdoutにJSONが返る
  - 同一バンドルの複数インスタンス並行実行: ○ クリックしたインスタンスにのみコールバックが届く
- **Implications**: CLIラッパー・IPC (FIFO / socket / 一時ファイル)・`open` 経由起動・並行呼び出しの衝突対策はすべて不要。残る制約は「バンドルをホーム以下の索引される場所に置く」ことのみ

### 初回起動・遅延exit・権限フローの確定

- **配置場所が効くのは初回の許可取得時のみ**: 許可済みBundle IDなら `/private/tmp` でも動く。新規IDの初回許可ダイアログは `~/Applications` 等の正規の場所に置いた場合のみ表示される。`lsregister -f` も `open` 経由も回避策にならない
- **遅延exitは必要**: 即exit (`exit-delay 0`) するとmacOSがアプリを再起動し、引数なしの新プロセスがデフォルト値のまま通知を1件出した (実測)。`exit-delay 1` で解消。さらに再起動されたのは同一Bundle IDで登録済みの**別の場所のコピー**だった → 同一Bundle IDのバンドルを複数箇所に登録してはならない
- **権限フロー**: 許可ダイアログ表示中は `requestAuthorization` が応答を待ち `--timeout` は進まない (`--timeout 5` で48秒待った実測)。拒否は `granted == false` ではなく `UNErrorDomain Code=1` のエラーで返り未許可状態と区別できない → error分岐・`granted == false` 分岐の両方で exit 2 (実測で終了コード2を確認済み)

### CLIインストールとバンドル外実行の実測 (2026-07-27)

- **Context**: 「リリースのバイナリを落として `yobirin install` を叩くだけ」の成立可否を確認するため、素のMach-O (バンドル外) での挙動を実測した
- **Findings**:
  - 引数なし起動は `UNUserNotificationCenter.current()` への到達で **SIGABRT (exit 134)**。`~/Library/Logs/DiagnosticReports` にクラッシュログが残る。真因は `UNNotificationCenterAdapter` の格納プロパティ `center` が非lazyでinit時に即評価されること
  - `--help` は exit 0 で正常動作。ArgumentParserは**マッチした葉コマンドの `run()` だけ**を呼ぶため、通知APIに触れないサブコマンドはバンドル外でも安全
  - 素のMach-Oから `Process` で `codesign --force --sign -` を起動してのad-hoc署名は成功する
  - ImageIOの `CGImageDestination` (UTType `com.apple.icns`) でicns生成が可能。ただし**各画像にDPIメタデータ (1x=72 / 2x=144) を付与しないとRetinaスロットが暗黙に捨てられ5サイズに劣化**する。付与すれば10スロットすべてが正しく生成されることを `iconutil -c iconset` での復元で確認済み
- **Implications**: インストール系サブコマンドは通知APIに触れない構造にすれば素のバイナリで完走できる。バンドル外検知を起動フローの最初に置き、通知系だけを遮断する

### 参考: ライト/ダーク別アイコンの調査 (2026-07-27)

- 通知バナーの白合成問題への対案としてライト/ダーク別バリアント (`.icon` 形式) を調査したが、**解決しない**ことを実測で確定 (詳細はImplementation Notes)。アイコン外観はダークモードではなく独立したグローバル設定に連動し、Apple純正アプリすらアピアランスで分岐しない (差分ピクセル0)。黒背景焼き込みが正解

### 検証しなかった手段とその理由

| 手段                                     | 未検証の理由                                                                |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `UserNotificationsKit` の `_icons`       | `allowable-clients` がApple製プロセス限定。ad-hocアプリからは到達不能       |
| 通知DB (`db2/db`) の直接編集             | Full Disk Access必須、DB破損リスクが利得を上回る                            |
| Notification Service / Content Extension | 別バンドルの拡張が必要。ローカル通知では発火せず、macOSでは主アイコン非対応 |
| Web Push / WidgetKit                     | ローカルCLIの構成から大きく外れる                                           |
| `responsibility_spawnattrs_setdisclaim`  | 通知の帰属先を変える手段であり、アイコン差し替えには不要                    |
| 自前 `NSPanel` 通知                      | Notification Centerを使わない設計変更そのもの                               |

## Architecture Pattern Evaluation

| Option                      | Description                                  | Strengths                                                 | Risks / Limitations                                                                        | Notes      |
| --------------------------- | -------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------- |
| 旧API (bare binary)         | `NSUserNotification` + なりすまし            | アイコン差し替え可、単一バイナリ配布                      | 他社アプリへのなりすましが前提。deprecated。却下検知はポーリング必須でバナー閉じは検知不可 | 採用しない |
| **新API (`.app` バンドル)** | `UNUserNotificationCenter` + symlink直接実行 | 却下をコールバックで即座に正確に検知。自分の名義。現行API | アイコンの実行時差し替え不可。バンドル必須                                                 | **採用**   |

## Design Decisions

### Decision: 新API + `.app` バンドル + ad-hoc署名 + バンドルアイコン焼き込み。なりすましは採用しない

- **Context**: 旧APIならなりすまし経由でアイコン差し替えが可能と判明し、新旧の選択が必要になった
- **Selected Approach**: `UNUserNotificationCenter` + `.app` バンドル。アイコンはビルド時焼き込み
- **Rationale**: (1) なりすましはOSSツールが利用者に無断で行う挙動として不適切 (2) 通知が自分の名義で出ず、システム設定で独立制御できないのはユーザーに不利益 (3) Appleが想定しない経路はいつ塞がれてもおかしくない (4) 当初の用途 (Claudeアイコンでの通知) はバンドルアイコンの焼き込みで満たせる
- **Trade-offs**: 通知ごとの任意アイコン指定を放棄。可変アイコンが必要になったら派生バンドルpoolを追加する

### Decision: 却下検知は `customDismissAction`、ポーリング禁止

- **Context**: alerterのメモリリークの根本原因が却下検知のポーリング実装 (RunLoopのないGCDスレッドでautoreleaseプールがdrainされない)
- **Selected Approach**: `UNNotificationCategoryOptions.customDismissAction` + delegateコールバック
- **Rationale**: ポーリングが存在しないため、リークが構造的に発生しない。バナーを閉じた瞬間を検知でき、精度も上回る
- **Follow-up**: 結果確定の排他 (`OSAllocatedUnfairLock` / actor) を最初から設計に入れる

### Decision: 配布はsymlink直接実行。ラッパー・IPCなし

- **Context**: 当初「`open` 起動 + IPC必須」と誤結論していたが、切り分け直しで訂正された
- **Selected Approach**: `~/Applications/Yobirin.app` + PATH上のsymlinkから直接実行。結果はstdoutへ同期出力
- **Rationale**: alerter / terminal-notifierと同じ配布形態で、実測により成立を確認済み
- **Trade-offs**: なし (単純化のみ)

### Decision: ライフサイクル保護 (遅延exit + 引数なしガード + timeout時の通知削除)

- **Context**: 即exitでmacOSがアプリを再起動して余計な通知を出す。SIGKILL後の孤児通知クリックでも空起動される (実測)
- **Selected Approach**: 結果出力後0.5〜1秒の遅延exit。引数なし起動は孤児通知を掃除して即exit。timeout時は通知を削除してから終了 (alerter準拠のライフサイクル)
- **Rationale**: 3つの防御で「exit後の通知クリックで再起動 → 誤通知」の経路をすべて塞ぐ

### Decision: プロファイル選択は単一コマンドの `--profile` ディスパッチへ変更 (2026-07-27、当初決定を改訂)

- **Context**: CLI自身がインストールを担う設計 (Requirement 11) の導入で、プロファイルごとにsymlinkコマンドが増殖する懸念が顕在化した
- **Alternatives Considered**:
  1. プロファイルごとのsymlink (当初決定) — 透明だがプロファイル数だけコマンドが増える
  2. `--profile <name>` で対象バンドルのMach-Oへexecする薄いディスパッチ
- **Selected Approach**: 案2。PATHのコマンドは `yobirin` 1本、プロファイルはAppだけが増える
- **Rationale**: 当初案2を棄却した理由は「Swift側が他バンドルの配置パスへ結合する」ことだったが、インストーラを内蔵した時点でCLIは配置規約を知っている。棄却理由が消滅したため再決定した
- **Trade-offs**: exec 1回分のオーバーヘッド (数ms) とディスパッチ実装の追加。呼び出し側 (dotfiles) は名前解決ロジックが不要になり単純化する

### Decision: バンドル組み立てはCLIに一元化し、シェルスクリプト2本を削除 (2026-07-27)

- **Context**: `install` サブコマンドがバンドルを組み立てられるなら、`build-app.sh` の組み立て部分と完全に重複する。リリースCIは既に `swift build` + `lipo` を直接呼んでいる
- **Selected Approach**: `build-app.sh` と `install.sh` を削除。CIは実行ファイル生成まで、バンドル組み立て・アイコン・署名・配置はCLIの `install` だけが担う (Requirement 9.3)
- **Build vs Adopt**: icns生成はImageIO (プラットフォーム内蔵、実測済み) を採用し `sips`/`iconutil` の外部起動を廃止。署名はAPIが存在しないため外部 `codesign` の起動を継続
- **Trade-offs**: ローカルで `.app` だけ欲しい場合も `swift build && .build/release/yobirin install` を使う (専用スクリプトはない)

### Decision: デフォルトアイコンは実行ファイルに埋め込む (2026-07-27)

- **Context**: 素のバイナリだけではリポジトリの `assets/icon/AppIcon.png` が手元にない (Requirement 11.4)
- **Selected Approach**: 標準アイコンのPNGバイト列を生成済みSwiftソースとしてコミットし、バイナリに同梱する。SPMのリソースバンドルは実行ファイル単体配布では使えない (バンドル外に置かれる) ため採用しない
- **Follow-up**: アイコン変更時は生成ファイルの再生成が必要 (手順をコメントで残す)

### 確定済みの論点一覧 (2026-07-26)

| 論点                 | 決定                                                                                                            |
| -------------------- | --------------------------------------------------------------------------------------------------------------- |
| ツール名 / Bundle ID | **yobirin** / `com.mjun0812.yobirin` (beckon / denrei / oshirase / noroshiと比較。Homebrew・GitHubとも衝突なし) |
| `--timeout` 省略時   | 無期限。hookからは必ず明示指定する運用 (UN APIはポーリングしないため放置してもリークしない)                     |
| 通知許可deny時       | 専用exit 2 + stderr。JSONは出さない (呼び出し側がfallback判定できる)                                            |
| MVPスコープ          | actions / replyも含むalerter同等のフル機能 (JSONスキーマとcategory設計の手戻り防止)                             |
| action identifier    | `yobirin-action-<index>` 形式。JSONにindexを載せる                                                              |
| バンドル組み立て     | swift-notifierの `build-app.sh` を踏襲 (M2aで手作業成立を確認済み)                                              |
| インストール先       | `~/Applications` 等の正規の場所。同一Bundle IDを複数箇所に登録しない                                            |

### Decision: `list` の対象判定は命名規約との往復一致、表示値はInfo.plistの実態 (2026-07-28)

- **Context**: Requirement 14 (インストール済みバンドルの一覧表示) の追加。`~/Applications` の走査で「yobirinのバンドルだけ」を確実に選別し、診断に使える情報を出す必要がある
- **Selected Approach**: (1) 対象判定は `ProfileNaming` の命名規約との**往復一致** — `Yobirin-<suffix>.app` はsuffixを小文字化→プロファイル名として検証→順方向導出がディレクトリ名と一致するもののみ採用。逆引きAPIは `ProfileNaming` へ追加。(2) 表示するBundle ID・バージョンは規約からの導出値ではなく配置済み `Info.plist` から読む。読めない項目は欠損 (`-` / `null`) で継続
- **Rationale**: 往復一致なら `Yobirin-My-App.app` (規約外) や `Yobirin-ABC.app` (導出不一致) を機械的に排除でき、判定ロジックの二重実装も生まれない。実態読み取りは「規約とズレた壊れバンドル」の診断にそのまま使える
- **Trade-offs**: Info.plist読み取りのI/Oが増えるが、一覧は対話用途で件数も少数のため無視できる。JSONスキーマ (`{"bundles":[...]}`) は新たな呼び出し側契約になるためRevalidation Triggerへ追加した

## Risks & Mitigations

- macOSアップデートで `customDismissAction` や再起動挙動が変わる — 手動検証チェックリストをOSアップデート後に再実行する
- 遅延exitの適正値 (0.5〜1秒) がOS挙動に依存 — 実装時に実測で再確認する (参考実装は0.5秒)
- 同一Bundle IDの複数登録による誤再起動 — インストーラ / アップグレードで旧バンドルを確実に削除する
- OSS配布時のGatekeeper — M4でDeveloper ID + notarizationを検討 (ad-hocはローカル利用まで)
- claude-notifications-go #105 (Codex対応) が解決された場合 — 乗り換えを再評価する

## References

- [docs/design-research.md](../../../docs/design-research.md) — 原本。競合分析・M2a実機検証の全記録
- [vjeantet/alerter](https://github.com/vjeantet/alerter) / [PR #65](https://github.com/vjeantet/alerter/pull/65) — 旧API側の教科書とリーク修正PR
- [claude-notifications-go swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier) — 新API側の主参考実装
- [Apple公式フォーラム: 通知アイコンのカスタマイズ不可](https://developer.apple.com/forums/thread/134147)
- [Implementing communication notifications](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications) — 候補C (棄却) の一次情報
