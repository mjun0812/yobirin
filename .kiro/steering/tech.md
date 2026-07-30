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
- **ビルド**: Swift Package (executableTarget)。バンドル組み立てはCLI自身の `install` サブコマンド (自己バイナリ複製 + ImageIOでのicns生成 + 外部codesign)。Xcodeプロジェクトもシェルスクリプトも使わない

## Development Environment

### Required Tools

- Xcode Command Line Tools (`swiftc`, `codesign`。releaseワークフローのユニバーサル化に `lipo`)

### Common Commands

```bash
# Build + Install: swift build -c release && .build/release/yobirin install
#   (自己バイナリ複製 → Info.plist生成 → icns焼き込み → ad-hoc署名 → ~/Applications 配置 → symlink → 起動検証)
# Profile: yobirin install --profile <name> --icon <path>
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
9. **CFBundleは実行パスのsymlinkを解決しない**。PATH上のsymlink経由のexecでは、バンドル内実体を指していても `Bundle.main.bundleIdentifier` がnilになる (UN層のLaunchServicesはrealpathで解決するため通知自体は出せる)。起動フローの最初で「バンドル未解決 かつ 実行パス≠realpath」を検知したら実体パスへ再execし、直接実行と同一条件に正規化する (2026-07-28実測)。

### 採用しない手段 (方針として禁止)

- **他アプリへのなりすまし**: alerterは `NSBundle.bundleIdentifier` をswizzleして `com.apple.Terminal` として通知を出しており、アイコン差し替えはこれが前提だった。yobirinは自分の名義で通知を出す。通知が自分の名義で出ず、システム設定で独立して制御できないのはユーザーに不利益。
- **私用API依存**: `UNNotificationIcon` / `content.icon` 等の私用APIは、通常アプリでは表示に反映されない (6種の生成メソッドすべてで確認済み)。使っても効果がなく、メンテ負債だけが残る。
- **通知ごとの任意アイコン指定 (`--icon`)**: 実現手段が存在しない。公開API・私用APIとも全滅。

### 設計上の決定

- **却下検知は `UNNotificationCategory` の `customDismissAction`** を使う。ポーリングは使わない (alerterのメモリリークの根本原因がポーリング実装だった)。
- **`--timeout` 省略時は無期限**。呼び出し側 (hook等) が必ず明示指定する運用。許可ダイアログ表示中はタイムアウトが進まない。
- **アイコンはインストール時にバンドルへ焼き込む** (icnsはImageIOで生成。各サイズにDPIメタデータ 1x=72/2x=144 が必須 — 欠くとRetinaスロットが無言で落ちる)。複数アイコンが必要な場合はプロファイルごとに別バンドルを用意し、`--profile <name>` で選択する。
- **CLI・JSON出力はalerter互換にしない**。ゼロから設計する。
- **コマンドは通知系とインストール系の2群に分類する**。インストール系 (`install` / `uninstall` / `list` / `ps` / `completion` / ヘルプ) は通知API (UserNotifications / AppKit) の型に一切触れず、素のバイナリで完走する。`doctor` のみ例外で、通知系に属するがバンドル外でも劣化して完走する (詳細はstructure.md)。命名規約 (バンドル名・Bundle ID・パス導出) は単一ソース (`ProfileNaming`) に集約する。
- **バンドル外でのコマンド種別判定は `parseAsRoot` の解決結果の型で行う** (2026-07-30)。引数の位置走査はオプションの値とサブコマンド名を区別できず、`--title install` のような入力でクラッシュしていた。`parseAsRoot` はパースの一環で `validate()` を実行するため、`validate()` に副作用 (標準入力の消費等) を置いてはならない。
- **短縮オプションに `allowingJoined: true` を指定しない**。`ProfileDispatch.buildExecArguments` のプロファイル指定の除去 (長短4形態) がこの前提に依存しており、破ると引き継ぎ先での再ディスパッチによりexecが無限ループする。

## Testing

**通知の表示・対話・権限フローは自動テストできない** (GUI依存)。人間が画面を見てクリックする必要がある。

- 自動テスト可能: 引数パース、JSON生成、group置換ロジック、終了コード、インストール系の組み立て・配置・一覧 (fake注入のテンポラリ領域テスト)、起動ゲート (ビルド済み実バイナリのプロセス起動による結合テスト)
- 手動確認が必須: 通知の表示、アイコン、クリック / 却下 / アクション / replyの検知、初回の許可ダイアログ

自動テストで完了と判断してはいけない。GUI依存部分は手動検証チェックリストで確認する。

テスト環境の既知の制約 (2026-07-28実測):

- `NSHomeDirectory()` は子プロセスの `HOME` 環境変数を反映しない。実プロセスでのinstall成功系・衝突系は実環境を汚さずに再現できないため、fake注入のテンポラリ領域テストで担保する
- xctestホストは `Bundle.main.bundleIdentifier` が非nil。「バンドル外」のシミュレートは判定の注入、または実バイナリのプロセス起動で行う

_updated: 2026-07-30 (cli-arguments-ux: parseAsRootベースの起動ゲート・doctorの例外・allowingJoined禁止を反映)_
