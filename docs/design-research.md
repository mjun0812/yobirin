---
title: "alerter代替の通知CLI yobirin の設計"
created: "2026-07-26"
updated: "2026-07-27"
model: "claude-fable-5"
---

# alerter代替の通知CLI yobirin の設計

macOSで「通知を出し、クリック/却下/タイムアウトを捕捉してJSONで返す」CLI **yobirin** (呼び鈴。鳴らして応答を待つ) をOSSとして自作するための設計メモ。既存ツール (vjeantet/alerter) のメモリリークが動機。bundle IDは `com.mjun0812.yobirin`。名前はHomebrew formula・GitHubとも衝突なし (2026-07-26確認、同名は0★の個人リポジトリのみ)。

## 背景

- dotfilesのClaude Code通知hook (`script/wezterm/alerter-wezterm-notify.sh`) が `alerter --json` を使っている。alerterは通知が操作されるまでブロックして待つ設計。
- alerterは非推奨の `NSUserNotification` APIを使っており、却下検知のために `deliveredNotifications` を毎秒約5回ポーリングする。GCDバックグラウンドスレッドにはRunLoopがなくautoreleaseプールがdrainされないため、通知放置中にメモリが増え続ける (実測: 48分で1.8GB、CPU 11%)。
- 修正PR [vjeantet/alerter#65](https://github.com/vjeantet/alerter/pull/65) (2026-03-06) は4ヶ月未マージ。リポジトリ自体は2026年に復活しているがレビューは停滞。
- terminal-notifierも実質メンテ停止。「クリック捕捉できる通知CLI」のニッチに現役の選択肢がない (詳細は競合分析を参照)。

## 競合分析 (2026-07-26調査)

| ツール                                                                                    | 実装 / 通知API                                                         | 状態                                                             | 対話捕捉 (クリック/却下)                                                                | 備考                                                                                                                                                        |
| ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [vjeantet/alerter](https://github.com/vjeantet/alerter)                                   | ObjC / NSUserNotification (非推奨)                                     | 1,206★。2026年に復活 (v26.5)、ただしリーク修正#65は4ヶ月未マージ | ○ (クリック・却下・reply・actionsをJSONで同期返却)                                      | 機能面では本家。リークと非推奨API依存が致命傷                                                                                                               |
| [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier)               | ObjC / NSUserNotification (非推奨)                                     | 7,266★。最終release 2017年 (2.0.0)。実質メンテ停止               | ✕ (fire-and-forget。クリック時挙動は `-activate`/`-execute` で間接指定、結果は返らない) | 知名度は最大。alerterはこれのfork                                                                                                                           |
| [variadico/noti](https://github.com/variadico/noti)                                       | Go                                                                     | 4,868★。GitHubはarchived、Codebergへ移転。2025-03にv3.8.0        | ✕                                                                                       | 「コマンド完了を知らせる」目的。Slack等への送信が主眼で対話捕捉は非目標                                                                                     |
| [dschep/ntfy](https://github.com/dschep/ntfy)                                             | Python                                                                 | 4,967★。メンテ薄い                                               | ✕                                                                                       | notiと同系統。push通知バックエンド中心                                                                                                                      |
| [vitorgalvao/notificator](https://github.com/vitorgalvao/notificator)                     | shell + osascript製.appラッパー                                        | 191★                                                             | ✕                                                                                       | Alfred workflow用。アイコン差し替えのために.appを動的生成する発想は参考になる                                                                               |
| [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications)                 | Swift / UNUserNotificationCenter                                       | 343★。活発 (push 2026-07)                                        | ○ (ボタン応答等を取得可能)                                                              | エンタープライズMDM向けの重量級agent。IT管理者がユーザーへ告知する用途で、CLIワンショット用途には過剰                                                       |
| [777genius/claude-notifications-go](https://github.com/777genius/claude-notifications-go) | Go + 内蔵Swift製 "terminal-notifier-modern" (UNUserNotificationCenter) | 760★。活発 (push 2026-07)                                        | ○ (click-to-focus。WezTerm/tmuxのpane・tab切替まで内蔵)                                 | Claude Code plugin機構専用 (マーケットプレイス配布)。Codex非対応 ([#105](https://github.com/777genius/claude-notifications-go/issues/105))、SSH/OSC通知なし |
| `osascript display notification`                                                          | macOS組み込み                                                          | -                                                                | ✕                                                                                       | アイコン指定も対話捕捉も不可                                                                                                                                |

### 分析から得られる結論

- **空席の確認**: 「モダンなUN APIで、通知への反応 (クリック/却下/reply/actions) を同期的に構造化データで返す汎用CLI」は存在しない。対話捕捉ができるのはalerter (リーク+非推奨API)、IBM (重量級・用途違い)、claude-notifications-go (プラグイン内部実装) の3つだけで、いずれも「軽量な汎用CLI」ではない。
- **最重要の参考実装**: claude-notifications-goの [`swift-notifier/`](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier)。「Swift Package (executableTarget) + シェルスクリプトでバンドル組み立て」構成でXcodeプロジェクトを使わない。M2aで判明した論点をすべて既に解いているので、実装前に必読 (詳細は下記)。
- **乗り換え評価の結果 (2026-07-26)**: claude-notifications-goへの全面乗り換えは検討の上で棄却した。理由は (1) Codex非対応 — [#105](https://github.com/777genius/claude-notifications-go/issues/105) がopenのままメンテナ反応なし。plugin機構 (`.claude-plugin/plugin.json` + マーケットプレイス) がClaude Code固有なので構造的な制約でもある。(2) SSHセッション時のOSC 777/9通知に相当する機能がない。(3) dotfilesのマルチagent一元管理 (Claude / Codex / Gemini / Antigravity) とplugin閉じ込め型の設計が相性最悪。#105が解決されたら再評価する。
- **教訓**: terminal-notifier/alerterの停滞理由はNSUserNotification廃止対応の負債。最初からUN APIのみを対象とし、私用APIハック (`-sender`, `--app-icon`) を採用しないことが長寿命の条件。

### 参考実装の具体的な参照ポイント

**[claude-notifications-go の `swift-notifier/`](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier)** (新APIの主参考)

[`scripts/build-app.sh`](https://github.com/777genius/claude-notifications-go/blob/main/swift-notifier/scripts/build-app.sh) が「Xcodeなしでバンドルを組み立てる」未決事項の答えそのもの:

- `swift build --arch arm64` と `--arch x86_64` を個別実行し `lipo -create` でユニバーサル化
- `.app/Contents/{MacOS,Resources}` を作り `Info.plist` を配置
- `sips` で9サイズのPNG (Retina `@2x` 含む) を生成 → `iconutil -c icns` でアイコン生成
- 署名を `--ci` フラグで切替: ローカルはad-hoc、CIは Developer ID + hardened runtime + notarization
- **署名後に `open -W -n <app> --args -help` でLaunchServicesスモークテスト**を実行し、署名済みアプリが実際に起動できるか検証する。yobirinのビルドにも入れる (署名ミスをビルド時に検出できる)

コード側の参照ポイント:

| ファイル                                                                   | 参照する理由                                                                                                                                                                                                            |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `App/AppDelegate.swift`                                                    | AppDelegate方式のライフサイクル。**`asyncAfter(deadline: .now() + 0.5)` で遅延exit** している。本設計も遅延exitが必要と実測で確定しており (即exitするとアプリが再起動され余計な通知が出る)、0.5秒という値の裏付けになる |
| `Notification/PermissionManager.swift`                                     | 権限フロー。本設計では実測で挙動を確定させたので、実装の書き方の参考として読む                                                                                                                                          |
| `Notification/NotificationCategory.swift`                                  | category設計                                                                                                                                                                                                            |
| `Notification/UNNotificationService.swift` / `NSNotificationService.swift` | 新旧API両対応の抽象化                                                                                                                                                                                                   |

**構成が異なる点**: swift-notifierは結果をCLI呼び出し元へ同期的に返す構成ではなく、Go側から起動してフォーカス制御する作り。yobirinは呼び出したプロセスのstdoutに結果を返すので、この部分は参考にしない (ただし追加検証によりIPCは不要と判明したため、独自設計が必要な箇所も残っていない)。

**副次的な参考**

- [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications): 活発にメンテされているSwift + UN API実装。ただしMDM向け常駐agentなので構造が違い、UNの使い方の教科書として部分参照する程度
- [vjeantet/alerter](https://github.com/vjeantet/alerter): **旧API側の教科書**。CLIオプション設計、`--group` の扱い、JSON出力、[PR #65](https://github.com/vjeantet/alerter/pull/65) (リーク修正) は読む価値がある。ただし通知の出し方そのものは真似できない (なりすまし前提のため)

### 本ツールの位置づけ: notify.shのバックエンド交換

現行のdotfiles通知系は「ルーター + バックエンド」の2層構造になっており、腐っているのはバックエンド (alerter) だけである:

```
Claude Code hooks ─┐
Codex hooks ───────┤→ notify.sh (ルーター)
                   │    ├─ SSH時: OSC 777/9 エスケープシーケンス (WezTerm/iTerm2/VSCode/Cursor、tmux passthrough)
                   │    ├─ ローカルmac: alerter-wezterm-notify.sh → alerter ← ★ここだけ交換
                   │    │    └─ クリック → activate-wezterm-pane.sh (pane活性化)
                   │    └─ Linux/WSL/Windows: notify-send / PowerShell toast
```

本ツールはこの `alerter` 呼び出し1箇所を差し替えるだけの部品として作る。これにより:

- Codex対応・OSC経路・Hammerspoon連携・他OS fallbackはすべて無傷で残る
- ルーター (notify.sh) と配線 (各agentのhook設定) には手を入れない
- 逆に、本ツール自体はdotfilesの事情を一切知らない汎用CLIとして設計できる (OSSとして独立可能)

## ゴール / 非ゴール

### ゴール

- alerterと**同等の機能**を実現する: 通知送信、クリック / 却下 / タイムアウトの捕捉、アクションボタン、reply入力、サウンド、グループ置き換え。結果は同期的に待って構造化データ (JSON) をstdoutへ出力して終了する
- ポーリングを使わず、`UNUserNotificationCenter` のdelegateコールバックで却下まで検知する (リークの構造的排除)
- `--timeout` によるプロセス生存時間の有界化
- dotfilesのhookから移行できること (hook側スクリプトの書き換えは許容)

### 非ゴール

- **alerterとのCLI・出力互換**: オプション名・JSONスキーマは互換を保たず、ゼロから設計する
- 私用APIに依存する機能の再現 (`-sender` によるアプリ偽装、`--app-icon` によるアイコン動的差し替え)。競合分析の教訓の通り、非公開API依存はメンテ負債になるため採用しない
- **他アプリへのなりすまし**: alerterは `NSBundle.bundleIdentifier` をswizzleして `com.apple.Terminal` として通知を出しており、アイコン差し替えはこれが前提だった (M2a実測)。yobirinは自分の名義で通知を出し、なりすましは行わない
- Linux / Windows対応
- 通知センターに常駐するデーモン化

## 要件

alerterの機能を棚卸しし、UN APIでの実現方法に読み替える。互換は保たないので、実現手段は自由に選べる:

| alerterの機能                                            | 新ツールでの実現                                                                   |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| タイトル・サブタイトル・本文                             | `UNMutableNotificationContent` の title / subtitle / body                          |
| グループ置き換え (`--group`)                             | 同一identifierでの `add` + `removeDeliveredNotifications`                          |
| クリック捕捉                                             | delegate + `UNNotificationDefaultActionIdentifier`                                 |
| 却下捕捉 (alerterはポーリング)                           | `UNNotificationCategoryOptions.customDismissAction` (コールバック、ポーリング不要) |
| アクションボタン (`-actions`, `-dropdownLabel`)          | `UNNotificationAction` の配列 (複数はOSが自動でドロップダウン化)                   |
| reply入力 (`-reply`)                                     | `UNTextInputNotificationAction`                                                    |
| サウンド (`-sound`)                                      | `UNNotificationSound`                                                              |
| 添付画像 (`-contentImage`)                               | `UNNotificationAttachment`                                                         |
| タイムアウト (`-timeout`)                                | タイマーで結果 `timeout` を確定してexit                                            |
| アプリ偽装 (`-sender`) / アイコン差し替え (`--app-icon`) | 非対応 (私用API依存のため。非ゴール参照)                                           |

現行hook (`alerter-wezterm-notify.sh`) が使っているのはtitle / message / group / JSON出力 / クリック判定のみなので、上記のサブセットが動けば移行できる。hook側の分岐は新スキーマに合わせて書き換える。

## アーキテクチャ

### .appバンドル必須問題

`UNUserNotificationCenter` はbundle identifierを持つアプリからしか使えないため、素のCLIバイナリでは動かない。alerter / terminal-notifierと同じ構造を採る:

```
Yobirin.app/
  Contents/
    Info.plist          # CFBundleIdentifier=com.mjun0812.yobirin, LSUIElement=true (Dockに出さない)
    MacOS/yobirin       # Swift製CLI実体
    Resources/AppIcon.icns
```

- `LSUIElement = true` でDockアイコン・メニューバーを出さない
- **PATHには `Contents/MacOS/yobirin` へのsymlinkを置き、直接実行する** (実測で動作確認済み。`open`/LaunchServices経由もラッパーも不要)
- **バンドルの設置場所はホーム以下の安定した場所** (`~/Applications` 等)。`/tmp` 系ではバンドルがアプリとして認識されず通知を出せない (これが唯一の制約)
- アイコンは初回インストール時からバンドルに含めておく。同じBundle IDに後からアイコンを追加してもキャッシュされた通知ソースには反映されない

### 実行フロー

1. 引数パース (Swift ArgumentParser)
2. `UNUserNotificationCenter.requestAuthorization` (初回のみダイアログ)
3. `--group` 指定時: 同一identifierの配信済み通知を `removeDeliveredNotifications` で除去
4. `customDismissAction` 付きの `UNNotificationCategory` を登録
5. 通知を `add` し、`NSApplication.run()` で待機 (M2a実測: `RunLoop.main.run()` だけでは `applicationDidFinishLaunching` が来ず通知許可が取れない。AppDelegate方式が必須)
6. delegateコールバック or タイマーで結果確定 → **結果JSONをstdoutへ出力** → **0.5〜1秒待って** `exit 0`
   - 遅延は必須。即exitするとmacOSがアプリを再起動し、余計な通知が出る (実測)。詳細は「初回起動・遅延exit・権限フローの確定」を参照

なお 0 の前段として、**引数 (リクエスト) なしで起動された場合は何も通知せず即exitするガード**を入れる。孤児通知のクリックによる再起動で誤って通知が出るのを防ぐ。

### 却下検知 (本ツールの核)

```swift
let category = UNNotificationCategory(
    identifier: "default",
    actions: [],
    intentIdentifiers: [],
    options: [.customDismissAction]  // 却下時もdidReceiveが呼ばれる
)

// delegate
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier: emit(.contentsClicked)
    case UNNotificationDismissActionIdentifier: emit(.closed)
    default: break
    }
    completionHandler()
}
```

ポーリングが存在しないので、alerter #65のようなautoreleaseプール問題は構造的に発生しない。

### 排他制御

結果確定は「クリック / 却下 / タイムアウト」の早い者勝ち。`OSAllocatedUnfairLock` か actor で一度きりの `emit` を保証する (alerter #65がNSLockで後付けした部分を最初から設計に入れる)。

### 通知のライフサイクル (alerter準拠、2026-07-26決定)

プロセス終了後の通知の扱いはalerterと同じ仕様とする (現行alerterのSwift実装 `NotificationManager.swift` で確認):

- 応答を受け付けるのは**プロセス生存中のみ**
- timeout時は通知を `removeDeliveredNotifications` で**削除してから** `timeout` を出力してexitする。exit後にクリックされ得る通知を残さないため、「通知クリックで.appが再起動される」問題は構造的に発生しない
- 無期限 (`--timeout` 省略) 時はプロセスが応答まで待ち続ける
- UN特有の補完: SIGKILL等の異常終了時は通知が残り、クリックで.appが空起動される。起動時に「応答待ちの主がいない配信済み通知」を掃除して即exitする処理を入れてこのエッジを塞ぐ

## アイコン差し替えの回避策調査 (2026-07-26)

UN APIでは通知アイコンは送信アプリのバンドルアイコンに固定され、通知ごとに変える公式手段はない ([Apple公式フォーラム](https://developer.apple.com/forums/thread/134147)、[Keyboard Maestroコミュニティ](https://forum.keyboardmaestro.com/t/custom-icon-for-macos-notifications/30303) とも結論一致)。カスタムUIを作れるUNNotificationContentExtensionもiOS専用。回避策を徹底調査した結果:

| 候補                                                 | 判定         | 内容                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A. 派生バンドル生成 (notificator方式)                | ○ 確実、本線 | アイコンだけ違う.appを生成して使い分ける。公開APIのみ。代償はバンドルごとの通知許可とシステム設定に複数並ぶこと                                                                                                                                                                                                                                                                                                                                     |
| B. `NSApp.applicationIconImage` 実行時差し替え       | △ 要実験     | claude-notifications-goの[swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier)が「通知に効く」前提のコメント付きで実戦投入している。一方「Dockにしか効かない」とする[報告](https://developer.apple.com/forums/thread/773550)もあり情報が割れている。効けば `--icon <path>` が公開APIだけで実装できる                                                                                                      |
| C. Communication Notifications (INSendMessageIntent) | △ 茨の道     | 送信者アバターを主アイコン位置に出せる[唯一の公式ルート](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications)でmacOSも対象。ただしentitlement `com.apple.developer.usernotifications.communication` がprovisioning profile必須でad-hoc署名では通らない可能性が高く、[iOSですらアバター表示に癖](https://developer.apple.com/forums/thread/687225)、macOSの第三者成功例は未確認。用途外利用でもある |
| D. UN私用APIハック                                   | ✕ 発見できず | 旧APIの `_identityImage` ([NSUserNotificationPrivate](https://github.com/indragiek/NSUserNotificationPrivate)) に相当するUN版隠しプロパティの報告はWeb上に存在しない                                                                                                                                                                                                                                                                                |
| E. icns書き換え / attachment                         | ✕            | attachmentは右側サムネイル止まり。icns書き換えはシステムのキャッシュが強く反映されない ([custom soundですらOS再起動が要る](https://developer.apple.com/forums/thread/759548))                                                                                                                                                                                                                                                                       |

結論: 本線は「ビルド時差し替え + 将来必要なら派生バンドル (A)」。候補B・C・Dは下記のM2a実機検証で**すべて否定された**。

## M2a 実機検証結果 (2026-07-26、macOS 26 / Darwin 25で実測)

Swiftのプロトタイプ (`main.swift` 約180行 + `.app` バンドル + ad-hoc署名) を組んで実機検証した。結果は上記の調査結論をすべて追認し、加えて**配布方式に関わる想定外の制約が2つ**見つかった。

| 検証項目                                                                  | 結果  | 備考                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/private/tmp` 配置 (Mach-O直接実行 / `open` 起動とも)                    | ✕     | `UNErrorDomain Code=1 "Notifications are not allowed for this application"`。`mdls` で `kMDItemCFBundleIdentifier = null`、索引外でバンドルがアプリとして認識されない                                                                                                                                                                            |
| ホーム以下配置 + `open` (LaunchServices) 起動                             | ○     | 通知配信成功                                                                                                                                                                                                                                                                                                                                     |
| **ホーム以下配置 + バンドル内Mach-Oの直接実行**                           | **○** | 通知配信成功 (後日検証、下記「IPCは不要」参照)。**当初「不可」と誤って記録していた**                                                                                                                                                                                                                                                             |
| バンドルアイコン (新Bundle IDで初回から埋め込み)                          | ○     | アイコンが正しく表示される                                                                                                                                                                                                                                                                                                                       |
| バンドルアイコン (既存Bundle IDに後から追加)                              | ✕     | 真っ白のまま。通知ソース記述がキャッシュされ再生成されない                                                                                                                                                                                                                                                                                       |
| `applicationIconImage` (候補B)                                            | ✕     | 通知アイコンは不変。Dock専用という公式仕様どおり                                                                                                                                                                                                                                                                                                 |
| `NSWorkspace.setIcon` (候補)                                              | ✕     | 戻り値は `true` だが通知アイコンは不変                                                                                                                                                                                                                                                                                                           |
| 私用API `UNNotificationIcon` + `content.icon` — **6メソッド全て** (候補D) | ✕     | `iconAtPath:` / `iconForApplicationIdentifier:` (WebKitが使う手法) / `iconForApplicationURL:` / `iconForSystemImageNamed:` / `iconWithData:` / `iconNamed:` のすべてで、**クラス・メソッドは実在し、生成も `content.icon` への設定も配信も例外なく成功するが、表示は一切変わらない**。サーバ側 `allowPrivateProperties` ゲートの存在が実証された |
| 私用 `shouldShowSubordinateIcon`                                          | △     | 副アイコンの**表示枠は出る**が、中身は注入した画像ではなくアプリ自身のアイコン。私用画像は採用されない                                                                                                                                                                                                                                           |
| Communication Notifications (候補C) — entitlement付き                     | ✕✕    | **アプリが起動すらできない**。`open` が `Launchd job spawn failed` (POSIX 163) で失敗。2回再現し、entitlement除去で起動が復帰する対照実験も確認済み。ad-hoc署名で制限付きentitlementを主張した時点でOSが実行を拒否する                                                                                                                           |
| Communication Notifications — entitlementなし                             | ✕     | `INInteraction.donate` と `content.updating(from: intent)` は**エラーなく成功**し配信も通るが、アバターは表示されずアイコンはアプリ自身のまま                                                                                                                                                                                                    |
| クリック検知                                                              | ○     | `{"result":"clicked"}`                                                                                                                                                                                                                                                                                                                           |
| **却下検知 (`customDismissAction`)**                                      | **○** | `{"result":"dismissed"}`。**ポーリング不要で取得でき、yobirinの最大の技術的前提が実証された**                                                                                                                                                                                                                                                    |
| 動的category登録 (呼び出しごとに構成変更)                                 | ○     | `setNotificationCategories` の呼び直しで機能する                                                                                                                                                                                                                                                                                                 |
| delegate内での即exit                                                      | ✕     | 「アプリケーションは既に閉じられています」ダイアログが出る。**結果出力後1秒待ってexitする**ことで解消                                                                                                                                                                                                                                            |

### 旧API (NSUserNotification) との比較検証 (2026-07-26実測)

「旧APIならアイコンを差し替えられるのだから、そちらを選ぶ価値はないか」を実機で検証した。結論は **alerterのアイコン差し替えは `com.apple.Terminal` へのなりすましによって成立している**。

| 検証                                                                                            | 結果                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 実物のalerter (`--app-icon`)                                                                    | ○ 指定PNGが主アイコン位置に表示される (`_identityImage` + `_identityImageHasBorder`)                                                                     |
| alerterをad-hoc署名で再署名して実行                                                             | ○ **変わらず動く**。署名は無関係 (Developer IDもHardened Runtimeも不要)                                                                                  |
| alerterのBundle IDだけを別IDへバイナリパッチ                                                    | ○ **変わらず動く**。Bundle IDも無関係                                                                                                                    |
| 自作の`.app`バンドル + 旧API + `_identityImage`                                                 | ✕ バンドルアイコンが優先され差し替わらない (.icns / PNGとも)                                                                                             |
| 自作の素のMach-O (Info.plist埋め込みなし)                                                       | ✕ 通知が表示されない                                                                                                                                     |
| 自作の素のMach-O + `__TEXT,__info_plist` 埋め込み (許可付与済み・固定パス・alerterと同じ起動順) | ✕ **表示されない**                                                                                                                                       |
| 自作の素のMach-O + **`NSBundle.bundleIdentifier` をswizzleして `com.apple.Terminal` を返す**    | **○ 表示され、Finderアイコンに差し替わる**                                                                                                               |
| 新APIを素のMach-Oで使用                                                                         | ✕ `UNUserNotificationCenter.current()` が `bundleProxyForCurrentProcess is nil` で**例外を投げてクラッシュ**。実体としての`.app`バンドルを厳格に要求する |

**なぜalerterでは動くのか**: alerterは [`Sources/BundleHook/BundleIdentifierHook.m`](https://github.com/vjeantet/alerter/blob/master/Sources/BundleHook/BundleIdentifierHook.m) で `NSBundle.bundleIdentifier` をswizzleし、`-sender` 未指定時は **`com.apple.Terminal` を返す**。つまりalerterの通知はTerminal.appからの通知として配信されている。これが全観測を一貫して説明する:

- ad-hoc署名でも動く → 署名は無関係。Terminalとして扱われるから
- 新しいBundle IDでも動く → そのIDは実際には使われていない
- 通知許可を求められない → Terminalが既に許可済み
- `_identityImage` が効く → **システムアプリの通知ソースとして扱われるため私用プロパティが採用される**
- 正直な実装 (なりすましなし) は表示すらされない

調査ドキュメントの `allowPrivateProperties` ゲートの記述と整合する。alerterはゲートを突破しているのではなく、**Appleのシステムアプリになりすましてゲートの内側に立っている**。

### 新APIでもなりすましは使えるか (2026-07-26実測)

旧APIで効いたなりすましを新APIでも試したが、**両手法とも拒否された**。

| 手法                                                                                        | 結果                                                                                                                                                  |
| ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.app`バンドル + `NSBundle.bundleIdentifier` を `com.apple.Terminal` にswizzle              | ✕ swizzle自体は成功 (`Bundle.main.bundleIdentifier` が `com.apple.Terminal` を返す状態) だが、`requestAuthorization` が `UNErrorDomain Code=1` で拒否 |
| 私用 `-[UNUserNotificationCenter initWithBundleIdentifier:]` に `com.apple.Terminal` を渡す | ✕ 呼び出し・オブジェクト生成は成功するが、通知は `UNErrorDomain Code=1` で拒否                                                                        |

**理由**: 新APIは身元を `NSBundle` ではなく **LaunchServicesのbundleProxy** から取得している (素のMach-Oで `bundleProxyForCurrentProcess is nil` の例外が出たことと整合)。プロセスの実体が身元の根拠なので、コード上の細工では変えられない。私用centerについては、調査ドキュメントの指摘通りサーバ側が「要求Bundle IDが呼出元自身のものか」を検証している。

つまりAppleは新APIで**なりすましの経路そのものを設計として閉じている**。旧APIの緩さが穴であったことの裏返しであり、新APIへ移行した理由の一つと考えられる。設計上は「なりすましをするか否か」という判断自体が発生しないため、かえって単純になる。

**この検証で私が2回誤った推論をした** (記録として残す): (1)「Developer ID署名が必要」→ ad-hoc再署名でも動いたため反証。(2)「新規Bundle IDの許可が定着しないため」→ alerterのIDを別IDへパッチしても動いたため反証。原因の切り分けは「同じコードでIDだけ変える」「同じIDでコードだけ変える」の交差実験で特定できた。

### 旧API vs 新API 総括

| 項目                       | 旧API (bare binary)                                                                           | 新API (`.app`バンドル)                                 |
| -------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| アイコンの通知ごと差し替え | ○ **ただし他社アプリへのなりすましが前提**                                                    | ✕ (全手段で不可)                                       |
| 必要な署名                 | ad-hocで可                                                                                    | ad-hocで可                                             |
| 実行形態                   | 素のMach-O + 埋め込みInfo.plist                                                               | `.app`バンドル必須                                     |
| 起動方法                   | 直接実行可 (配布が単一バイナリで済む)                                                         | `open`/LaunchServices経由が必須 (ラッパー + IPCが必要) |
| 通知の名義                 | **なりすまし先 (Terminal等) の名義**。システム設定でも独立して制御できない                    | 自分の名義。独立して制御できる                         |
| 通知許可                   | なりすまし先の許可に便乗                                                                      | 初回ダイアログで明示的に許可                           |
| 却下検知                   | ポーリング必須。しかも**バナーを閉じただけでは検知できない** (通知センターから消えるまで待つ) | コールバックで即座に正確に検知                         |
| 将来性                     | macOS 11でdeprecated。なりすましもいつ塞がれてもおかしくない                                  | 現行API                                                |

**決定**: yobirinは**新API + `.app`バンドル + ad-hoc署名 + バンドルアイコン焼き込み**で作り、**なりすましは採用しない**。理由:

1. アイコン差し替えの代償が「他社アプリへのなりすまし」であり、OSSツールが利用者に無断で行う挙動として不適切
2. 通知が自分の名義で出ず、システム設定で独立して制御できないのはユーザーにとって不便 (Terminalの通知を切ると巻き込まれる)
3. Appleが想定しない経路なので、いつ塞がれてもおかしくない
4. 当初の用途 (Claudeアイコンでの通知) はバンドルアイコンの焼き込みで満たせるため、実質的な損失がない

なお、この検証で **Apple Developer Program加入は不要**であることも確定した (署名は無関係だった)。加入の実利はOSS配布時のnotarizationと、Communication Notificationsの再検証に限られる。

### 検証しなかった手段とその理由

網羅性のため、調査ドキュメントの候補のうち実測しなかったものを明示する:

| 手段                                     | 未検証の理由                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------ |
| `UserNotificationsKit` の `_icons`       | `allowable-clients` がApple製プロセスに限定。ad-hocアプリからは到達不能        |
| 通知DB (`db2/db`) の直接編集             | Full Disk Access必須、DB破損・既存通知消失のリスク。実験の危険が利得を上回る   |
| Notification Service / Content Extension | 別バンドルの拡張が必要。ローカル通知では発火せず、macOSでは主アイコン非対応    |
| Web Push / WidgetKit                     | ローカルCLIの構成から大きく外れる                                              |
| `responsibility_spawnattrs_setdisclaim`  | アイコンではなく通知の帰属先を変える手段。LaunchServices起動で解決するため不要 |
| 自前 `NSPanel` 通知                      | Notification Centerを使わない別路線。アイコン回避策ではなく設計変更そのもの    |

### この検証で確定した設計変更

1. ~~**symlinkをPATHに置く配布方式は不可**~~ → **誤り。訂正済み** (下記「IPCは不要だった」参照)。真因は配置場所であり、実行方法ではなかった。
2. **インストール先はホーム以下の安定した場所**が必要 (`~/Applications` 等)。一時ディレクトリ (`/private/tmp` 等) では通知を出せない。**これが唯一の配置制約**。
3. **アイコンは「バンドルに焼く」以外に手段がない**。実行時変更は公開・私用ともに全滅。可変アイコンが要るなら派生バンドル (候補A) しかない。
4. **結果出力後の遅延exit**を仕様に含める。
5. **ad-hoc署名では制限付きentitlementを一切付けられない**。付けた瞬間に起動不能になるため、entitlementを要求する機能 (Communication Notifications、time-sensitive等) は設計から除外する。

### IPCは不要だった (2026-07-26 追加検証、前言訂正)

M2aで「symlink方式は不可、`open`/LaunchServices起動 + IPCが必須」と結論したが、**これは誤りだった**。M2aの最初の実験で「配置場所 (`/private/tmp`)」と「実行方法 (Mach-O直接実行)」を同時に変えてしまい、失敗の原因を実行方法に誤って帰属させていた。切り分け直した結果:

| 検証                                         | 結果                                                                                             |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| ホーム以下のバンドル内のMach-Oを**直接実行** | **○ 通知が配信される**                                                                           |
| PATHに置いた**symlink経由**で実行            | **○ 動作する** (`Bundle.main` は正しく`.app`に解決される)                                        |
| 結果の同期取得                               | **○ そのプロセスのstdoutにJSONがそのまま返る**                                                   |
| **同一バンドルの複数インスタンス並行実行**   | **○ クリックしたインスタンスにのみコールバックが届く**。他のインスタンスは影響を受けず待機を継続 |

真因は「バンドルを `/private/tmp` に置いていたこと」だけだった (Spotlight索引外でバンドルがアプリとして認識されない)。

**この訂正による設計の単純化**:

- CLIラッパーは不要 — PATHにsymlinkを置くだけでよい (alerter / terminal-notifierと同じ配布形態)
- **IPC (FIFO / Unix socket / 一時ファイル) は不要** — 結果はstdoutに直接書く
- `open`/LaunchServices経由の起動も不要
- 遅延exitも不要になる可能性が高い (LaunchServicesがアプリをアクティブ化しないため。実装時に確認)
- 並行呼び出しの衝突対策も不要 (プロセスごとに独立してコールバックが届く)

残る制約は**バンドルをホーム以下の索引される場所に置く**ことのみ。

### 初回起動・遅延exit・権限フローの確定 (2026-07-26 追加検証)

「見込み」で残していた3点を実測で確定させた。ここでも当初の推測が外れており、**配置場所が効くのは初回の許可取得時だけ**だった。

#### 1. 通知が出せる条件 = Bundle IDの許可状態 (配置場所は初回のみ関係)

| 段階                          | 条件                                                                  | 結果                                                 |
| ----------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------- |
| **許可済み**Bundle IDでの実行 | `~/Applications` / `/opt/homebrew/Cellar` / **`/private/tmp` すべて** | ○ 動く。**場所は無関係**                             |
| 新規IDの初回                  | `/private/tmp` + 直接実行                                             | ✕ `Code=1`。ダイアログも出ない                       |
| 新規IDの初回                  | `/private/tmp` + `lsregister -f` 後に直接実行                         | ✕ 変わらず `Code=1`                                  |
| 新規IDの初回                  | `/private/tmp` + **`open` 経由**                                      | ✕ 変わらず `Code=1`                                  |
| 新規IDの初回                  | **`~/Applications` + 直接実行**                                       | **○ 許可ダイアログが出る。許可すれば以降通知が出る** |

`lsregister` も `open` も回避策にはならない。**バンドルを正規の場所 (`~/Applications` 等) に置くことだけが条件**であり、それさえ満たせばラッパー・IPC・`open`・ブートストラップ手順はすべて不要。

#### 2. 遅延exitは必要 (ただし理由はダイアログではなく再起動の抑制)

直接実行でクリックを受けて**即exit (`exit-delay 0`) すると、macOSがアプリを再起動する**。実測では、クリックを正しく受けて `{"result":"clicked"}` を返した直後に引数なしの新プロセスが起動し、デフォルト値のまま通知を1件出してしまった。

- `exit-delay 0` → 「既に閉じられています」ダイアログは出ない (これは`open`起動時のみの症状) が、**再起動により余計な通知が出る**
- `exit-delay 1` → 再起動もダイアログも起きない

さらに、再起動されたのは通知を送った `~/Applications` のコピーではなく、**同じBundle IDで登録されていた別の場所のコピー**だった。LaunchServicesはBundle IDから登録済みのいずれかを選ぶため、**同一Bundle IDのバンドルを複数箇所に登録してはならない** (インストーラは旧コピーを確実に削除する)。

**必要な実装は2つ**:

1. 結果出力後に短い遅延 (0.5〜1秒) を置いてexitする — 再起動の抑制
2. **引数なし (リクエストなし) で起動された場合は、何も通知せず即exitするガード** — SIGKILL後に孤児通知をクリックされた場合など、遅延では防げない経路の保険

#### 3. 権限フロー

- 許可ダイアログ表示中は `requestAuthorization` が応答を待ち、**`--timeout` は進まない** (`--timeout 5` で48秒待った実測)。タイマーは認可コールバック後に開始する実装で正しい
- **拒否は `granted == false` ではなく `UNErrorDomain Code=1` のエラーとして返る**。未許可状態と同じエラーなので区別できない。error分岐・`granted == false` 分岐の**両方で `exit 2`** にする
- 終了コード2が返ることを実測で確認済み

### 改訂後のアーキテクチャ

```text
notify.sh (ルーター)
    │
    ▼
yobirin (PATH上のsymlink → ~/Applications/Yobirin.app/Contents/MacOS/yobirin)
    ├─ UNUserNotificationCenterで通知
    ├─ clicked / dismissed / action / replied / timeout を待つ
    ├─ 結果JSONをstdoutへ出力
    └─ exit
```

alerterと同じ「単一コマンドを呼んで結果をstdoutで受け取る」使い勝手になる。違いは、実体が素のMach-Oではなく`.app`バンドル内のMach-Oであること (新APIの要件) だけ。

`--icon` オプションは提供しない (実現手段がないため)。アイコンはビルド時にバンドルへ焼き込む。

### アイコンのプロファイル方式

任意画像の実行時指定は不可能だが、**アイコンはバンドルの属性なので、アイコンだけ違うバンドルを複数用意すれば使い分けられる** (M2aで実測確認済み: 新Bundle IDでアイコンを焼き込んだバンドルはそのアイコンで通知が出る)。dotfilesの用途ではClaude用とCodex用の2種類で足りるため、これを最初から設計に含める:

```text
~/Applications/Yobirin-Claude.app   (Claudeアイコン, com.mjun0812.yobirin.claude)
~/Applications/Yobirin-Codex.app    (Codexアイコン,  com.mjun0812.yobirin.codex)
$PATH/yobirin -> (デフォルトプロファイルのMach-O)
```

`yobirin --profile claude` のように指定し、symlinkまたは薄いディスパッチで対象バンドルのMach-Oを実行する。

代償と利点:

- 代償: 初回の通知許可がプロファイルごとに必要、システム設定の通知一覧にプロファイルごとの項目が並ぶ、インストール時に複数バンドルを配置する必要がある
- 利点: **「Claudeの通知だけオフにする」といった制御がユーザー側でできる**

## CLIインターフェース (案)

```
yobirin --title <str> --message <str>
        [--subtitle <str>]
        [--group <id>]           # 同一groupの既存通知を置き換え
        [--timeout <sec>]        # 省略時は無期限 (hookからは必ず指定する運用)
        [--action <label>]...    # 複数指定可。2つ以上はOSがドロップダウン表示
        [--reply [placeholder]]  # テキスト入力アクション
        [--sound default|<name>]
        [--image <path>]         # UNNotificationAttachment (サムネイル)
```

### 出力JSONスキーマ

alerter互換の制約はないため、結果種別と付随データを分離したスキーマをゼロから設計する:

```json
{ "result": "clicked", "deliveredAt": "2026-07-26T12:00:00+09:00" }
{ "result": "action",  "action": "Open" }
{ "result": "replied", "text": "入力されたテキスト" }
{ "result": "dismissed" }
{ "result": "timeout" }
```

- `result`: `clicked` | `action` | `replied` | `dismissed` | `timeout`
- 終了コードは常に0 (結果はJSONで表現)
- 環境エラーはJSONを出さず非0で終了する。通知許可denyは**専用のexit 2** + stderrに理由を出力し、呼び出し側 (notify.sh) がosascript等へfallbackできるようにする。「ユーザーの応答はJSON、環境エラーは非0」の区別を一貫させる
- hook側は `jq -r '.result'` で分岐するよう書き換える

## 配布

| 方式                            | 署名                         | 備考                                                     |
| ------------------------------- | ---------------------------- | -------------------------------------------------------- |
| 自分用 (dotfiles)               | ad-hoc署名                   | `codesign -s -` で動く。まずここから                     |
| GitHub Release (バイナリ)       | Developer ID + 公証 ($99/年) | Gatekeeper回避に必須                                     |
| Homebrew formula (ソースビルド) | 不要                         | alerterがMacPortsで採った方式。Xcode CLTがあればビルド可 |

初期はdotfiles内でソースビルド (`swift build` + バンドル組み立てスクリプト) → 使い物になったらリポジトリ分離してformula化、の2段階が現実的。

インストール構成 (Homebrew formulaも同様):

```text
~/Applications/Yobirin.app/          # バンドル本体 (ホーム以下必須)
$PATH/yobirin -> ~/Applications/Yobirin.app/Contents/MacOS/yobirin   # symlink
```

Homebrew formulaについては、**許可取得後なら `/opt/homebrew/Cellar/...` でも動作することを実測済み**。ただし**初回の許可ダイアログが表示されるのは `~/Applications` 等の正規の場所に置いた場合のみ**なので、formulaでは `~/Applications` へバンドルを配置する (または `caveats` で案内する) 方式を採る。あわせて、アップグレード時に**旧バージョンのバンドルを確実に削除する** (同一Bundle IDが複数登録されると、LaunchServicesが意図しないコピーを再起動する)。

## マイルストーン

1. ~~**M1 (止血・本設計とは独立)**~~ **不要 (2026-07-27)**: M2bが先に完了したため止血は行わない
2. ~~**M2a (検証スパイク)**~~ **完了 (2026-07-26)**: 「M2a 実機検証結果」を参照。アイコン戦略・却下検知・動的categoryのすべてに結論が出た
3. ~~**M2b (MVP)**~~ **完了 (2026-07-27)**: kiro spec `yobirin-cli` (`.kiro/specs/yobirin-cli/`) として全14タスクを実装・検証済み (最終検証GO)。alerter同等のフル機能 + JSON出力 + アイコンプロファイル機構 (派生バンドル + symlink方式)。手動検証で孤児通知掃除のバグを発見・修正した (実装ノート参照)。アプリアイコン (神社の鈴 + 鈴緒 + 青海波) も適用済み
4. ~~**M4a (private公開)**~~ **完了 (2026-07-27)**: README日英2言語 (通知許可ダイアログの説明、既知の制限を含む) とMITライセンスを整備し、[github.com/mjun0812/yobirin](https://github.com/mjun0812/yobirin) へprivateでpush済み。dotfilesからのインストールをGitHub経由 (clone + `scripts/install.sh`) にするため、M3より先行した (2026-07-27にM3と順序を入れ替え。リポジトリは当初から独立して作られているため「リポジトリ分離」は不要になった)
5. **M3 (差し替え完了、放置テスト継続中)**: dotfilesのhook (`notify.sh` → `yobirin-wezterm-notify.sh`) をyobirinへ差し替え済み (2026-07-27、dotfiles commit `067191a`)。アイコンの出し分けはalerterの私用API `--app-icon` を捨て、プロファイル派生バンドル (`yobirin-claude` / `yobirin-codex`) で実現した。`notify.sh` の第4引数はPNGパスからプロファイル名へ変更。Claude/Codex両hook経路で通知配信とクリック→WezTerm pane活性化を実機確認済み。**残り: 実運用でのメモリ・CPUの長期観測**
6. ~~**M2c (CLI内蔵インストーラ)**~~ **完了 (2026-07-28)**: kiro spec `yobirin-cli` の拡張 (Requirements 11〜13、tasks 6〜9) として実装・検証済み (最終検証GO)。バンドル組み立て・icns生成・署名・配置・検証を `yobirin install` サブコマンドへ内蔵し、`scripts/build-app.sh` / `install.sh` を廃止。リリースの素バイナリ1つで `install` → 通知まで完走する。プロファイル選択は per-profileコマンド (`yobirin-claude` 等) から単一コマンドの `--profile <name>` ディスパッチへ変更。**dotfiles連携はこの新方式 (`yobirin install --profile <name> --icon <path>` + `--profile` 呼び出し) への追従が必要**。検証中にsymlink経由起動の誤判定リグレッションを発見・修正した (CFBundleがsymlinkを解決しない問題。実体パスへの再execで正規化)
7. **M4b (public化)**: 実運用で安定を確認後にvisibilityをpublicへ変更。必要ならHomebrew tap (この段階でDeveloper ID署名 + notarizationを再検討)

## 未決事項 (詰めるポイント)

- [x] ツール名: **yobirin** に決定 (2026-07-26)。bundle IDは `com.mjun0812.yobirin`。候補はbeckon / denrei / oshirase / noroshiと比較し、「鳴らして応答を待つ」という動作との一致と衝突ゼロで選定
- [x] アイコン戦略: **ビルド時にバンドルへ焼き込む方式に決定** (2026-07-26、M2a実測)。実行時差し替えは公開API・私用APIとも全滅したため `--icon` オプションは提供しない。可変アイコンが必要になったら派生バンドルpool (候補A) を追加する
- [x] `--timeout` 省略時のデフォルト: **無期限**に決定 (2026-07-26)。hook (notify.sh) からは必ず `--timeout` を明示指定する運用でカバーする。UN APIはポーリングしないため、放置プロセスが残ってもalerterのようなリーク・CPU消費はない
- [x] 通知許可deny時の挙動: **専用exit 2 + stderr**に決定 (2026-07-26)。JSONは出さず、呼び出し側がfallback判定できるようにする
- [x] MVP (M2) スコープ: **actions/replyも含むalerter同等のフル機能**に決定 (2026-07-26)。JSONスキーマとUNNotificationCategory設計の手戻りをなくす
- [x] UNNotificationCategory: **採用決定** (2026-07-26、M2a実測)。`customDismissAction` による却下検知と、呼び出しごとの動的登録 (`setNotificationCategories` の呼び直し) がともに機能することを確認。actionのidentifierは `yobirin-action-<index>` 形式とし、JSONにはindexを載せる (同名ラベルでも識別可能)
- [x] CLIラッパーと本体間のIPC設計: **不要と判明したため廃止** (2026-07-26、追加検証)。PATH上のsymlinkからバンドル内Mach-Oを直接実行すれば通知が出せ、結果はstdoutに同期的に返る。並行実行時もコールバックは配信元インスタンスにのみ届く。詳細は「IPCは不要だった」を参照
- [x] 権限フローの詳細: **確定** (2026-07-26実測)。許可ダイアログ表示中は `requestAuthorization` が応答を待ち `--timeout` は進まない (`--timeout 5` で48秒待った)。タイマーは認可コールバック後に開始する実装で正しい。拒否は `granted == false` ではなく `UNErrorDomain Code=1` のエラーで返るため、**error分岐と `granted == false` の両方で `exit 2`** にする
- [x] 遅延exitの必要性: **必要と確定** (2026-07-26実測)。即exitするとmacOSがアプリを再起動して余計な通知を出す。0.5〜1秒の遅延で解消。あわせて「引数なし起動なら即exit」ガードを実装する
- [x] インストール先の条件: **正規の場所 (`~/Applications` 等) に置くことのみ** (2026-07-26実測)。許可取得後は場所を問わず動作するが、初回の許可ダイアログは `/private/tmp` では `open` 経由でも表示されない。`lsregister` は回避策にならない。**同一Bundle IDのバンドルを複数箇所に登録しない** (LaunchServicesが別コピーを再起動してしまう)
- [x] Swift Package構成でXcodeprojなしにバンドルを組み立てる方法: **swift-notifierの [`build-app.sh`](https://github.com/777genius/claude-notifications-go/blob/main/swift-notifier/scripts/build-app.sh) を踏襲する** (2026-07-26)。`swift build` × 2アーキ → `lipo` → バンドル組み立て → `sips` + `iconutil` でアイコン → 署名 → `open` によるLaunchServicesスモークテスト。M2aで手作業で成立を確認済み
