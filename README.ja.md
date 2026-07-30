<p align="center">
  <img src="assets/icon/AppIcon.png" width="160" alt="yobirinのアイコン (神社の鈴)" />
</p>

<h1 align="center">yobirin</h1>

<p align="center"><b>yobirin</b> (呼び鈴) は、鳴らして応答を待つmacOS向けの通知CLIです。</p>

<p align="center">
  <a href="https://github.com/mjun0812/yobirin/actions/workflows/ci.yml"><img src="https://shieldcn.dev/github/mjun0812/yobirin/ci.svg?size=xs" alt="CI" height="20" /></a>
  <img src="https://shieldcn.dev/badge/platform-macOS-gray.svg?size=xs" alt="Platform: macOS" height="20" />
  <img src="https://shieldcn.dev/badge/Swift-6.0-orange.svg?size=xs" alt="Swift 6.0" height="20" />
  <a href="LICENSE"><img src="https://shieldcn.dev/badge/license-MIT-blue.svg?size=xs" alt="License: MIT" height="20" /></a>
</p>

<p align="center"><a href="README.md">English README is here</a></p>

yobirinは、macOSの通知を配信し、ユーザーの反応 (クリック、却下、アクションボタン、テキスト返信、タイムアウト) を待って、結果をJSONで出力するCLIです。ShellScriptやツールのhookから、通知への反応で処理を分岐できます。

```console
$ yobirin --title "Deploy" --message "リリースを承認しますか?" --action "承認" --action "却下" --timeout 60
{"result":"action","action":"承認","actionIndex":0}
```

## Features

- **応答の捕捉**：クリック、却下、アクション選択、テキスト返信、タイムアウトを区別してJSONで返します
- **低リソース**：ポーリングを使わず、`UserNotifications` frameworkのdelegateコールバックだけで待ちます。通知を放置してもCPUもメモリも消費しません
- **容易な導入**：リリースのバイナリ1つで `yobirin install` するだけです。ビルドツールチェーンは要りません
- **自由な通知の振り分け**：Profileを切り替えることで、自由にアイコンや名前を設定して通知を出し分けられます
- **状態の可視化**：`yobirin list` がProfileを、`yobirin ps` が通知の応答待ちのプロセスを一覧表示します

## Usecase

### 完了通知から次の動作へ

長いビルドやテストの完了を知らせ、クリックされたらログを開きます。無視されたり閉じられたりしたら、何もせず終わります:

```bash
yobirin -t "ビルド完了" -m "ログを開きますか?" --timeout 5m --exit-code
[ $? -eq 0 ] && open build.log   # exit 0 = クリックされた
```

### 承認してから実行する

アクションボタンで確認を取り、承認されたときだけ先へ進みます:

```bash
yobirin -t "Deploy" -m "本番へリリースしますか?" \
  -a "承認" -a "却下" --timeout 10m --exit-code
if [ $? -eq 10 ]; then   # exit 10 = 1つ目のアクション (承認)、11 = 却下
  ./deploy.sh production
fi
```

### coding agentのhookから指示を受け取る

Claude CodeやCodexの通知hookに組み込むと、タスク完了の通知に返信して、そのまま次の指示を送れます。:

```bash
text=$(yobirin -p claude -t "Claude Code" \
  -m "タスクが完了しました。続きの指示があれば返信してください" \
  --reply --print text --timeout 5m)
[ -n "$text" ] && echo "$text" >> next-instructions.txt
```

### 中止の機会を与えてから自動実行する

タイムアウトを「応答がなければ実行」の合図として使います。席にいれば止められて、いなければ予定どおり進みます:

```bash
yobirin -t "メンテナンス" -m "5分後にバックアップを開始します" \
  -a "今すぐ開始" -a "中止" --timeout 5m --exit-code
[ $? -eq 11 ] && exit 0   # exit 11 = 2つ目のアクション (中止)
./backup.sh               # timeout (4) と「今すぐ開始」(10) はどちらも実行へ
```

## 動作要件

- macOS (Apple Silicon / Intel)
- Xcode Command Line Tools (ソースからビルドする場合のみ)

## インストール

### リリースバイナリから (ツールチェーン不要)

ビルド済みバイナリをダウンロードして、バイナリ自身にインストールさせます:

```console
$ curl -fsSL -o yobirin https://github.com/mjun0812/yobirin/releases/latest/download/yobirin
$ chmod +x yobirin
$ ./yobirin install
```

`install` を実行すると、バイナリが自分自身を複製してad-hoc署名した `Yobirin.app` を組み立て、`~/Applications` へ配置し、コマンドを `~/.local/bin/yobirin` へsymlinkします。`~/.local/bin` をPATHに通しておいてください (配置先は `YOBIRIN_BIN_DIR` で変更できます)。ダウンロードしたファイルは、インストールが済めば削除して構いません。

ブラウザでReleasesページからダウンロードした場合は、quarantine属性が付くため初回実行がGatekeeperにブロックされます。実行前に属性を外してください (curlでのダウンロードでは属性が付かないので不要です):

```console
$ xattr -d com.apple.quarantine ./yobirin
```

### miseから

[mise](https://mise.jdx.dev/) のgithubバックエンドでも取得できます。取得したバイナリで `install` を一度実行すればセットアップは完了です:

```console
$ mise use -g github:mjun0812/yobirin
$ yobirin install
```

miseが配置するのは素のバイナリですが、`install` 済みであれば通知要求は自動的にインストール済みバンドルへ引き継がれるので、そのまま `yobirin --title ...` が使えます。miseでバージョンを上げたときは、`yobirin install` を再実行してバンドル側も更新してください (更新が必要なときはCLIがその旨を表示します)。

### ソースから

```console
$ git clone https://github.com/mjun0812/yobirin.git
$ cd yobirin
$ swift build -c release
$ .build/release/yobirin install
```

アップグレードは `yobirin install` の再実行だけです。旧バンドルを削除してから新バンドルを配置するので、macOSに登録されるコピーは常に1つに保たれます。

## 通知の許可

`yobirin install` を実行すると確認用の通知が1件送られ、「Yobirin」の通知許可ダイアログが表示されるので、**許可**を選んでください。通知が届く状態かどうかを、実際に通知が必要になる場面より前に確かめられます。

- 確認用の通知が送られるのは新規インストールのときだけです。同じバンドルへの再インストールでは送られません
- インストールは確認用の通知の応答を待ちません。通知を受け取れない環境 (CIやパッケージマネージャのpostinstallなど) でもインストールは成功します
- プロファイルはバンドルが別なので許可も別に必要です。`install --profile <名前>` でも同じように確認用の通知が送られます
- ダイアログが表示されるのは、バンドルが `~/Applications` などの正規の場所にある場合だけです。インストーラがそこへ配置するので、通常は意識する必要はありません
- ダイアログの表示中、`--timeout` は進みません。タイマーが動き出すのは許可が確定してからです
- 許可されなかった場合 (後からオフにした場合を含む) は、JSONを出力せず、stderrへ理由を出して終了コード `2` で終了します。システム設定 > 通知 > Yobirin から再度オンにできます

## 使い方

```
yobirin -t <文字列> -m <文字列>         # --title / --message
        [-p <名前>]                    # --profile: プロファイルのバンドルで配信する
        [--subtitle <文字列>]
        [--group <id>]                 # 同じgroupの既存通知を置き換える
        [--timeout <期間>]             # 300、90s、5m、1h30m。省略時は無期限に待つ
        [-a <ラベル>]...                # --action: 複数指定可。2つ以上はドロップダウン表示になる
        [--reply]                      # テキスト入力アクションを追加する
        [--reply-placeholder <文字列>]  # 入力欄のplaceholder (--replyと併用)
        [--sound default|<名前>]
        [--image <パス>]               # png/jpg/jpeg/gifを添付する (既知の制限を参照)
        [--exit-code]                  # 結果を終了コードに反映する (後述)
        [--print <フィールド>]          # JSONの代わりに1フィールドだけ出力する
```

`--timeout` には秒数、または `h`/`m`/`s` 付きの期間 (`90s`、`5m`、`1h30m`) を指定します。省略すると応答があるまで無期限に待つので、hookや自動化から呼ぶときは必ず指定してください。

`--message -` は本文を標準入力から読みます。ログの末尾を流し込むときに便利です: `tail -3 build.log | yobirin -t Build -m -`

### 出力

結果が確定すると、JSONオブジェクトを1つstdoutへ出力します:

```json
{"result":"clicked"}
{"result":"action","action":"承認","actionIndex":0}
{"result":"replied","text":"入力されたテキスト"}
{"result":"dismissed"}
{"result":"timeout"}
{"result":"canceled"}
```

- `result`：`clicked`、`action`、`replied`、`dismissed`、`timeout`、`canceled` のいずれか
- `action` / `actionIndex`：押されたアクションボタンのラベルと0始まりのindex (同名ラベルはindexで区別できます)
- `text`：返信欄に入力されたテキスト

`--print <フィールド>` を付けると、結果JSONの代わりに指定フィールド (`result` / `action` / `actionIndex` / `text`) の値だけを生の文字列で出力します。`$(...)` でそのまま変数に入ります。結果にそのフィールドが無い場合 (却下されたのに `--print text` など) は何も出力せず、正常終了します。

終了コード:

| コード    | 意味                                       | stdout              |
| --------- | ------------------------------------------ | ------------------- |
| 0         | ユーザーの応答またはタイムアウトを捕捉した | 結果JSON            |
| 2         | 通知の許可が得られていない                 | なし (理由はstderr) |
| その他非0 | 環境エラー (引数不正、添付の失敗など)      | なし                |

`--exit-code` を付けると、終了コードが常に0ではなく結果を反映するようになり、JSONを解析せずに `$?` だけで分岐できます:

| 結果                   | 終了コード       |
| ---------------------- | ---------------- |
| clicked または replied | 0                |
| dismissed              | 3                |
| timeout                | 4                |
| canceled               | 5                |
| action                 | 10 + actionIndex |

許可なし (2) と環境エラー (1) のコードは変わりません。

タイムアウトした通知は、通知センターから削除してから終了するので、応答されないまま残ることはありません。強制終了などで通知だけが残った場合は、`yobirin sweep` で掃除できます (削除した件数を表示します)。

応答待ちのyobirinプロセスへSIGTERMを送ると、キャンセルとして扱われます。自分が配信した通知を通知センターから削除したうえで `{"result":"canceled"}` を出力して終了します (`--exit-code` 指定時は終了コード5)。`--group` の文字列はプロセスのargvに載っているので、hookから1行で古い通知を片付けられます。

```bash
# hookは応答待ちプロセスを殺すことで、古い通知を片付けられる
pkill -f "dotfiles-wezterm-${SESSION_ID}"
```

PIDを管理する必要はありません。SIGINTは対象外で、既定の動作のままです。

### 待機中プロセスの一覧

いま何が応答を待っているのかは、`yobirin ps` で確認できます。`--timeout` を付け忘れて放置された通知を見つけるのに便利です:

```console
$ yobirin ps
PID    PROFILE    TITLE   TIMEOUT  ELAPSED
4211   (default)  Deploy  5m00s    42s
4300   claude     Done    -        12m30s
```

`--json` を付けると機械可読な出力になります (タイムアウトは秒数で出ます)。`--profile <名前>` で特定プロファイルのプロセスだけに絞り込めます。

## アイコンプロファイル

通知のアイコンは、配信元アプリバンドルのアイコンに固定されます。これはmacOSの制約で、通知ごとにアイコンを指定する手段は存在しません。そこでyobirinでは、アイコンとBundle IDだけが異なる派生バンドルをインストールして使い分けます:

```console
$ yobirin install --profile claude --icon assets/icon/claude.png
$ yobirin --profile claude --title "Claude" --message "完了"
```

1行目で `Yobirin-Claude.app` (Bundle ID `com.mjun0812.yobirin.claude`) が指定アイコンで配置され、2行目以降は `--profile <name>` を付けるだけでそのバンドルの名義とアイコンで通知が出ます。実行はディスパッチで対象バンドルへ引き継がれるため、プロファイルを増やしてもPATH上のコマンドは `yobirin` 1本のまま増えません。各プロファイルは初回に独立して通知許可を求め、システム設定にも別項目として並ぶので、プロファイル単位でオン/オフできます。

プロファイル名に使えるのは英小文字と数字だけです (`^[a-z0-9]+$`)。`--icon` を省略すると、同梱の標準アイコン (鈴) が使われます。

インストール済みのバンドルは `yobirin list` で一覧できます (`--json` 対応):

```console
$ yobirin list
PROFILE    BUNDLE ID                    VERSION  PATH
(default)  com.mjun0812.yobirin         1.1.0    /Users/you/Applications/Yobirin.app
claude     com.mjun0812.yobirin.claude  1.1.0    /Users/you/Applications/Yobirin-Claude.app
```

## シェル補完

`yobirin completion <shell>` で `bash` / `zsh` / `fish` 向けの補完スクリプトを出力します:

```bash
# zsh (fpath上の補完ディレクトリへ。例: ~/.zfunc)
yobirin completion zsh > ~/.zfunc/_yobirin

# bash
yobirin completion bash > /usr/local/etc/bash_completion.d/yobirin

# fish
yobirin completion fish > ~/.config/fish/completions/yobirin.fish
```

## トラブルシューティング

`yobirin doctor` が、インストール済みバンドルとそのバージョン、実行中バイナリとの一致、PATH上のsymlink、通知許可の状態を1コマンドで点検します。問題を検出した項目には次に取るべき操作が併記され、問題があれば非0で終了します:

```console
$ yobirin doctor
ok       bundle      /Users/you/Applications/Yobirin.app (version 1.2.0)
ok       profiles    claude, codex
ok       version     1.2.0
ok       link        /Users/you/.local/bin/yobirin -> ...
failure  permission  Denied
                     -> Enable notifications in System Settings > Notifications > Yobirin.

1 problem(s) found
```

`--json` を付けると機械可読な出力になります。

## 既知の制限

- `--image`：添付自体はmacOSに受理、保存されますが、現行のmacOSはバナーにも通知センターにもサムネイルを描画しません
- 通知バナーは、アプリアイコンの透過部分を白と合成して描画します。他のmacOSアプリと同様に、不透明な角丸タイルを背景に持たせ、透過はタイルの外側 (四隅) だけに留めたアイコンを使ってください
- インストール済みバンドルのアイコンを差し替えても、通知バナーに反映されるのはログアウトして再ログインした後です (通知ソースのアイコンをOSが強くキャッシュするため)。すぐ反映したい場合は、新しいプロファイル名でインストールしてください。アイコンが変わる上書きインストールでは、CLIがその場でこの案内を表示します
- macOS専用です。LinuxとWindowsに対応する予定はありません

## アンインストール

バンドルの削除は `uninstall` で行います。macOSへのアプリ登録 (LaunchServices) もあわせて解除するため、手で `rm` するより確実です。

```console
$ yobirin uninstall                     # デフォルトのバンドルを削除
$ yobirin uninstall --profile claude    # プロファイルのバンドルを削除
```

`uninstall` はPATH上の `yobirin` コマンドを削除しません。miseやHomebrew経由で導入した場合、PATH上にあるのはそれらが管理する実バイナリであり、yobirinが消してしまうとパッケージマネージャ側の管理状態が壊れるためです。コマンドごと消すには、導入に使った方法で削除してください。

```console
$ mise uninstall github:mjun0812/yobirin   # miseで入れた場合
$ rm -f ~/.local/bin/yobirin               # 手動インストールの場合
```

## 仕組み

yobirinの実体は、1つのCLIバイナリです。ただし、macOSの現行通知API (`UserNotifications` framework) には「通知を出せるのは `.app` バンドルとして登録されたアプリだけ」という制約があり、素のバイナリから呼ぶと動きません。旧APIの `NSUserNotification` にはこの制約がありませんが、非推奨であるうえ、却下の検知にポーリングが必要でメモリリークの温床になるため使っていません。

そこで `yobirin install` は、実行中のバイナリが自分自身を複製して `Yobirin.app` を組み立て、ad-hoc署名して `~/Applications` へ配置し、PATH上の `yobirin` コマンドをその中の実行ファイルへのsymlinkとして張ります:

```text
~/.local/bin/yobirin  →  ~/Applications/Yobirin.app/Contents/MacOS/yobirin  (symlink)
```

つまり、CLIとして呼んでいるのはアプリの中のバイナリそのものです。通知を出すときだけアプリとして振る舞って応答を待ち (Dockには表示されません)、結果が確定したら終了します。常駐はしません。`install` や `list`、`ps` は通知APIに触れない、ただのCLIとして動きます。

アイコンプロファイルは、この仕組みの応用です。同じバイナリを、アイコンとBundle IDだけ変えた別のアプリ (`Yobirin-Claude.app` など) として複製し、`--profile` 指定時はそのバンドル内のバイナリへ実行を引き継ぎます。macOSから見ればそれぞれ独立したアプリなので、通知の許可もアイコンも名義も別々に扱われます。

## 開発

```console
$ mise install            # mise.tomlにpinした開発ツールの導入 (prek, shfmt, shellcheck, oxfmt)
$ prek install            # pre-commit hookの有効化 (swift format / shfmt / shellcheck / oxfmt)
$ swift test              # ユニットテストと結合テスト (通知センターはモック)
$ swift build -c release && .build/release/yobirin install   # ビルドしてローカルへインストール
```

開発ツールは [mise](https://mise.jdx.dev/) で管理しています。CI (GitHub Actions) は `main` へのpushとpull requestでビルド、テスト、lint (swift format / oxfmt) を実行し、ツールは `mise.toml` と同じバージョンを使います。

通知の表示、対話、許可フローはGUIに依存するため、自動テストでは検証できません。specと手動検証チェックリストは `.kiro/specs/yobirin-cli/` に、設計の経緯と実測記録は `docs/design-research.md` にあります。

## ライセンス

[MIT](LICENSE)

## 参考リンク

- [vjeantet/alerter](https://github.com/vjeantet/alerter)：yobirinの設計の下敷きになった、対話捕捉型の通知CLIです。このツールのメモリリークが開発の動機になりました
- [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier)：alerterのfork元にあたる、古典的なmacOS通知CLIです
- [777genius/claude-notifications-go / swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier)：XcodeプロジェクトなしにSwift Packageから署名済み `.app` バンドルを組み立てる方法の参考実装です
- [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications)：設計時に参照した、活発にメンテナンスされているSwift + `UserNotifications` 実装です
- [Apple: UserNotifications framework](https://developer.apple.com/documentation/usernotifications)：yobirinが使っている通知APIです
