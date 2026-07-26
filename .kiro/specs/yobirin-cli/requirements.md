# Requirements Document

## Project Description (Input)

macOS向け通知CLI「yobirin」の開発。UNUserNotificationCenterを使い、通知送信とクリック/却下/アクション/reply/タイムアウトの捕捉を行い、結果JSONをstdoutへ同期出力するCLI。vjeantet/alerterのメモリリーク(非推奨NSUserNotification APIのポーリング起因)の代替として開発する。.appバンドル+ad-hoc署名+PATH上のsymlinkという構成で、設計と実機検証はdocs/design-research.mdで完了済み。requirementsとdesignは再生成せず既存ドキュメントから移植する予定。

## Introduction

yobirin (呼び鈴) は、macOSで通知を1件配信し、ユーザーの反応 (クリック / 却下 / アクション / reply / タイムアウト) を同期的に待って結果JSONをstdoutへ出力するワンショット型通知CLIである。既存ツールalerterのメモリリーク (非推奨 `NSUserNotification` APIでの却下検知ポーリングが原因。実測: 48分で1.8GB、CPU 11%) を動機とし、モダンな `UNUserNotificationCenter` のdelegateコールバックのみで同等機能を実現する。

本要件は `docs/design-research.md` で完了済みの設計・実機検証 (2026-07-26、macOS 26 / Darwin 25) からの移植である。

## Boundary Context

- **In scope**: yobirin CLI本体 (通知送信・応答捕捉・結果JSON出力・終了コード)、`.app` バンドルのビルドスクリプト、インストール構成 (`~/Applications` 配置 + PATH上のsymlink)、アイコンプロファイル (派生バンドル)
- **Out of scope**: alerterとのCLI・JSON出力互換、通知ごとの任意アイコン指定 (`--icon`)、他アプリへのなりすまし・私用API利用、Linux / Windows対応、常駐デーモン化、Homebrew formula化・Developer ID署名・公証 (OSS化フェーズM4)、dotfiles側 (notify.sh / hookスクリプト) の書き換え
- **Adjacent expectations**: dotfilesの通知ルーター notify.sh がバックエンドとして本CLIを呼び出す。hook側は `jq -r '.result'` で分岐するよう別途書き換える (本specの外)

## Requirements

### Requirement 1: 通知の送信

**Objective:** シェルスクリプトやhookから通知を出したい開発者として、CLIオプションで内容を指定して通知を1件送信したい。それにより、スクリプトからmacOSの通知を扱える。

#### Acceptance Criteria

1. `--title <str>` と `--message <str>` を指定して実行されたとき、yobirin は指定されたtitle / bodyを持つ通知を `UNUserNotificationCenter` で配信しなければならない
2. `--subtitle <str>` が指定されたとき、yobirin は通知にsubtitleを設定しなければならない
3. `--sound default|<name>` が指定されたとき、yobirin は `UNNotificationSound` を通知に設定しなければならない
4. `--image <path>` が指定されたとき、yobirin は `UNNotificationAttachment` としてサムネイル画像を添付しなければならない
5. yobirin は通知を常に自身の名義 (自身のBundle ID) で配信しなければならず、他アプリへのなりすまし (`NSBundle.bundleIdentifier` のswizzle等) を行ってはならない

### Requirement 2: グループによる置き換え

**Objective:** 同種の通知を積み上げたくない開発者として、同一グループの既存通知を新しい通知で置き換えたい。

#### Acceptance Criteria

1. `--group <id>` が指定されたとき、yobirin は通知の配信前に同一identifierの配信済み通知を `removeDeliveredNotifications` で除去しなければならない
2. `--group` が指定されないとき、yobirin は既存の配信済み通知を除去してはならない

### Requirement 3: 応答の捕捉と結果JSONの出力

**Objective:** 通知への反応で処理を分岐したい開発者として、クリック / 却下 / アクション / reply / タイムアウトを構造化データで同期的に受け取りたい。

#### Acceptance Criteria

1. 通知本体がクリックされたとき、yobirin は `result: "clicked"` の結果JSONをstdoutへ出力しなければならない
2. 通知が却下されたとき、yobirin は `customDismissAction` のdelegateコールバックでこれを検知し、`result: "dismissed"` の結果JSONを出力しなければならない
3. アクションボタンが押されたとき、yobirin は押されたactionのindexとラベルを含む `result: "action"` の結果JSONを出力しなければならない
4. replyテキストが入力されたとき、yobirin は入力テキストを含む `result: "replied"` の結果JSONを出力しなければならない
5. タイムアウトが確定したとき、yobirin は `result: "timeout"` の結果JSONを出力しなければならない
6. ユーザー応答またはタイムアウトで終了するとき、yobirin は終了コード0で終了しなければならない
7. yobirin は却下検知のためにポーリングを使用してはならない
8. クリック / 却下 / タイムアウトが競合したとき、yobirin は最初に確定した結果のみを一度だけ出力しなければならない (排他制御)

### Requirement 4: アクションボタンとreply入力

**Objective:** 通知から選択や入力を受け取りたい開発者として、アクションボタンとテキスト入力を通知に付けたい。

#### Acceptance Criteria

1. `--action <label>` が1回以上指定されたとき、yobirin は各ラベルを `UNNotificationAction` として通知カテゴリに登録しなければならない (2つ以上はOSがドロップダウン表示する)
2. actionのidentifierは `yobirin-action-<index>` 形式とし、結果JSONでindexにより識別できなければならない (同名ラベルでも識別可能にするため)
3. `--reply` が指定されたとき (placeholderは `--reply-placeholder <str>` で任意指定)、yobirin は `UNTextInputNotificationAction` を登録しなければならない
4. yobirin は呼び出しごとに `setNotificationCategories` を呼び直し、通知カテゴリを動的に登録しなければならない

### Requirement 5: タイムアウトと通知のライフサイクル

**Objective:** hookから呼び出す開発者として、プロセスの生存時間を有界化し、応答され得ない通知を残したくない。

#### Acceptance Criteria

1. `--timeout <sec>` が指定されたとき、yobirin は指定秒数以内に応答がなければ結果を `timeout` として確定しなければならない
2. timeoutで確定したとき、yobirin は配信済み通知を `removeDeliveredNotifications` で削除してから結果JSONを出力して終了しなければならない (exit後にクリックされ得る通知を残さない)
3. `--timeout` が省略されたとき、yobirin は応答があるまで無期限に待機しなければならない
4. タイムアウトのタイマーは、通知許可の認可コールバック後に開始しなければならない (許可ダイアログ表示中はタイムアウトを進めない)
5. yobirin が応答を受け付けるのはプロセス生存中のみとする

### Requirement 6: プロセス終了とアプリ再起動への防御

**Objective:** 利用者として、yobirinの終了や異常終了をきっかけに余計な通知が出ないでほしい。

#### Acceptance Criteria

1. 結果JSONの出力後、yobirin は0.5〜1秒の遅延を置いてから終了しなければならない (即exitするとmacOSがアプリを再起動し、余計な通知が出る)
2. 引数なしで起動されたとき、yobirin は通知を出さずに即終了しなければならない (SIGKILL等の後に残った孤児通知のクリックで再起動される経路への防御)
3. 引数なしで起動されたとき、yobirin は応答待ちの主がいない配信済み通知を掃除しなければならない

### Requirement 7: 通知許可とエラー処理

**Objective:** 呼び出し側スクリプトの作者として、通知が出せない環境をユーザー応答と区別して検知し、fallbackへ切り替えたい。

#### Acceptance Criteria

1. yobirin は起動時に `requestAuthorization` で通知許可を要求し、初回は許可ダイアログの応答を待たなければならない
2. 通知許可が得られないとき (`UNErrorDomain Code=1` のエラー、または `granted == false` のいずれの経路でも)、yobirin はJSONを出力せず、stderrへ理由を出力し、終了コード2で終了しなければならない
3. 環境エラーで終了するとき、yobirin はJSONを出力せず非0の終了コードで終了しなければならない (ユーザー応答はJSON + exit 0、環境エラーは非0という区別を一貫させる)

### Requirement 8: .appバンドルと配布構成

**Objective:** 利用者として、PATHの通ったコマンドとして呼ぶだけで通知が出て、結果が同期的に返ってきてほしい。

#### Acceptance Criteria

1. yobirin の実体は `.app` バンドル内のMach-Oでなければならない (素のMach-Oでは `UNUserNotificationCenter.current()` が `bundleProxyForCurrentProcess is nil` で例外死する)
2. バンドルの `Info.plist` には `CFBundleIdentifier` (デフォルト: `com.mjun0812.yobirin`) と `LSUIElement = true` (Dock非表示) を設定しなければならない
3. PATH上のsymlinkからバンドル内Mach-Oを直接実行でき、結果JSONが呼び出し元プロセスのstdoutへ返らなければならない (ラッパー・IPC・`open` 経由起動は使わない)
4. インストール時、バンドルは `~/Applications` 等の正規の場所へ配置しなければならない (初回の通知許可ダイアログが表示される唯一の条件。`/private/tmp` 等ではダイアログが出ない)
5. インストール・アップグレード時、同一Bundle IDの旧バンドルを確実に削除しなければならない (LaunchServicesが別コピーを再起動する問題の防止)
6. アイコンはビルド時にバンドルへ焼き込まなければならず、`--icon` のような実行時アイコン指定オプションを提供してはならない (実現手段が存在しない)

### Requirement 9: ビルドパイプライン

**Objective:** 開発者として、Xcodeプロジェクトなしで再現可能に `.app` バンドルをビルドしたい。

#### Acceptance Criteria

1. yobirin はSwift Package (executableTarget) とシェルスクリプトでバンドルを組み立てなければならず、Xcodeプロジェクトを使ってはならない
2. ビルドスクリプトは、arm64 / x86_64 の個別ビルド → `lipo` によるユニバーサル化 → バンドル組み立て → `sips` + `iconutil` によるicns生成 → ad-hoc署名、の手順で `.app` を生成しなければならない
3. 署名後、ビルドスクリプトは `open -W -n <app> --args ...` によるLaunchServices起動スモークテストを実行しなければならない (署名ミスをビルド時に検出する)
4. ad-hoc署名のバンドルに制限付きentitlementを付与してはならない (付与するとアプリが起動不能になる)

### Requirement 10: アイコンプロファイル

**Objective:** 用途別のアイコンで通知を出し分けたい開発者として、アイコンだけが異なる派生バンドルを使い分けたい。

#### Acceptance Criteria

1. yobirin は、アイコンとBundle IDのみが異なる派生バンドル (プロファイル。例: `Yobirin-Claude.app` = `com.mjun0812.yobirin.claude`) を複数ビルド・配置できなければならない
2. プロファイルが選択されたとき、対象プロファイルのバンドル内Mach-Oが実行され、そのバンドルのアイコンと名義で通知が配信されなければならない
3. 通知許可はプロファイルごとに独立して取得され、システム設定上もプロファイルごとに独立して制御できなければならない
