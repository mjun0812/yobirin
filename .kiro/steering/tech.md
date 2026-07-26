# Technology Stack

## Architecture

macOS向けのワンショット型通知CLI。通知を1件送り、ユーザーの反応 (クリック / 却下 / アクション / reply / タイムアウト) を同期的に待って、結果JSONをstdoutへ出力して終了する。

`UNUserNotificationCenter` (モダンAPI) を使う。非推奨の `NSUserNotification` は使わない。

```text
PATH上のsymlink → ~/Applications/Yobirin.app/Contents/MacOS/yobirin (直接実行)
    ├─ UNUserNotificationCenterで通知
    ├─ clicked / dismissed / action / replied / timeout を待つ
    ├─ 結果JSONをstdoutへ出力
    └─ 短い遅延後にexit
```

ラッパープロセス・IPC・`open`(LaunchServices)経由の起動はいずれも不要 (実測で確認済み)。

## Core Technologies

- **Language**: Swift
- **Frameworks**: UserNotifications, AppKit
- **配布形態**: `.app` バンドル + PATH上のsymlink
- **ビルド**: Swift Package (executableTarget) + シェルスクリプトでバンドル組み立て。Xcodeプロジェクトは使わない

## Development Environment

### Required Tools

- Xcode Command Line Tools (`swiftc`, `codesign`, `lipo`, `sips`, `iconutil`)

### Common Commands

```bash
# Build: scripts/build-app.sh   (swift build ×2アーキ → lipo → バンドル組み立て → 署名 → 起動スモークテスト)
# Install: ~/Applications へバンドル配置 + PATHにsymlink
```

## Key Technical Decisions

すべて2026-07-26の実機検証 (macOS 26 / Darwin 25) に基づく。詳細な検証記録は `docs/design-research.md` を参照。

### 絶対に守る制約 (破ると動かない / ユーザーに不利益)

1. **`.app` バンドルが必須**。素のMach-Oで `UNUserNotificationCenter.current()` を呼ぶと `bundleProxyForCurrentProcess is nil` で例外死する。埋め込みInfo.plistでも回避できない。
2. **初回の通知許可ダイアログは、バンドルを正規の場所 (`~/Applications` 等) に置いた場合のみ表示される**。`/private/tmp` 等では `lsregister` しても `open` 経由でもダイアログが出ず `UNErrorDomain Code=1` になる。許可取得後は場所を問わず動作する。
3. **結果出力後に0.5〜1秒の遅延を置いてexitする**。即exitするとmacOSがアプリを再起動し、余計な通知が出る。
4. **引数 (リクエスト) なしで起動された場合は、何も通知せず即exitするガードを持つ**。孤児通知のクリックによる再起動対策。
5. **同一Bundle IDのバンドルを複数箇所に登録しない**。LaunchServicesがBundle IDから別コピーを選んで再起動することがある。インストーラは旧コピーを確実に削除する。
6. **`NSApplication.run()` + AppDelegate方式で起動する**。`RunLoop.main.run()` だけでは `applicationDidFinishLaunching` が来ず通知許可が取れない。
7. **通知許可の拒否は `granted == false` ではなく `UNErrorDomain Code=1` のエラーで返る**。error分岐と `granted == false` 分岐の両方で `exit 2` にする。
8. **制限付きentitlementを付けない**。ad-hoc署名で `com.apple.developer.usernotifications.communication` 等を主張すると、アプリが起動すらできなくなる (`Launchd job spawn failed`)。

### 採用しない手段 (方針として禁止)

- **他アプリへのなりすまし**: alerterは `NSBundle.bundleIdentifier` をswizzleして `com.apple.Terminal` として通知を出しており、アイコン差し替えはこれが前提だった。yobirinは自分の名義で通知を出す。通知が自分の名義で出ず、システム設定で独立して制御できないのはユーザーに不利益。
- **私用API依存**: `UNNotificationIcon` / `content.icon` 等の私用APIは、通常アプリでは表示に反映されない (6種の生成メソッドすべてで確認済み)。使っても効果がなく、メンテ負債だけが残る。
- **通知ごとの任意アイコン指定 (`--icon`)**: 実現手段が存在しない。公開API・私用APIとも全滅。

### 設計上の決定

- **却下検知は `UNNotificationCategory` の `customDismissAction`** を使う。ポーリングは使わない (alerterのメモリリークの根本原因がポーリング実装だった)。
- **`--timeout` 省略時は無期限**。呼び出し側 (hook等) が必ず明示指定する運用。許可ダイアログ表示中はタイムアウトが進まない。
- **アイコンはビルド時にバンドルへ焼き込む**。複数アイコンが必要な場合はプロファイルごとに別バンドルを用意する。
- **CLI・JSON出力はalerter互換にしない**。ゼロから設計する。

## Testing

**通知の表示・対話・権限フローは自動テストできない** (GUI依存)。人間が画面を見てクリックする必要がある。

- 自動テスト可能: 引数パース、JSON生成、group置換ロジック、終了コード
- 手動確認が必須: 通知の表示、アイコン、クリック / 却下 / アクション / replyの検知、初回の許可ダイアログ

自動テストで完了と判断してはいけない。GUI依存部分は手動検証チェックリストで確認する。
