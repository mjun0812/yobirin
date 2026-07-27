<p align="center">
  <img src="assets/icon/AppIcon.png" width="160" alt="yobirinのアイコン (神社の鈴)" />
</p>

<h1 align="center">yobirin</h1>

<p align="center"><b>yobirin</b> (呼び鈴) は、鳴らして応答を待つmacOS向けの通知CLIです。</p>

<p align="center">
  <a href="https://github.com/mjun0812/yobirin/actions/workflows/ci.yml"><img src="https://github.com/mjun0812/yobirin/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform: macOS" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT" /></a>
</p>

<p align="center"><a href="README.md">English README is here</a></p>

通知を出すだけなら `osascript` でもできます。見えないのはその先です。通知はクリックされたのか、閉じられたのか、どのボタンが押され、何が入力されたのか。yobirinは通知を1件配信し、その反応を同期的に待って、結果をJSONとしてstdoutへ返して終了します。シェルスクリプトやツールのhookが、通知への反応で分岐できるようになります。

```console
$ yobirin --title "Deploy" --message "リリースを承認しますか?" --action "承認" --action "却下" --timeout 60
{"result":"action","action":"承認","actionIndex":0}
```

## 特徴

- **応答の捕捉**：クリック、却下、アクション選択、テキスト返信、タイムアウトを区別してJSONで返します
- **リークしない待機**：ポーリングを使わず、`UserNotifications` frameworkのdelegateコールバックだけで待ちます。通知を放置してもCPUもメモリも消費しません
- **1コマンドの導入**：リリースのバイナリ1つで `yobirin install` するだけです。ビルドツールチェーンは要りません
- **アイコンの使い分け**：プロファイル機構で、アイコンと名義だけが異なる通知を出し分けられます
- **状態の可視化**：`yobirin list` がインストール状況を、`yobirin ps` が応答待ちのプロセスを一覧します
- **なりすまさない**：通知は常にyobirin自身の名義で出します。システム設定から独立してオン/オフできます

## ユースケース

### 完了通知から次の動作へ

長いビルドやテストの完了を知らせ、クリックされたらログを開きます。無視されたり閉じられたりしたら、何もせず終わります:

```bash
result=$(yobirin --title "ビルド完了" --message "ログを開きますか?" --timeout 300)
case "$(echo "$result" | jq -r '.result')" in
  clicked) open build.log ;;
esac
```

### 承認してから実行する

アクションボタンで確認を取り、承認されたときだけ先へ進みます:

```bash
answer=$(yobirin --title "Deploy" --message "本番へリリースしますか?" \
  --action "承認" --action "却下" --timeout 600)
if [ "$(echo "$answer" | jq -r '.action')" = "承認" ]; then
  ./deploy.sh production
fi
```

### coding agentのhookから指示を受け取る

Claude CodeやCodexの通知hookに組み込むと、タスク完了の通知に返信して、そのまま次の指示を送れます。プロファイルを使えば、通知はagentのアイコンと名義で表示されます:

```bash
reply=$(yobirin --profile claude --title "Claude Code" \
  --message "タスクが完了しました。続きの指示があれば返信してください" \
  --reply --timeout 300)
text=$(echo "$reply" | jq -r 'select(.result == "replied") | .text')
[ -n "$text" ] && echo "$text" >> next-instructions.txt
```

### 中止の機会を与えてから自動実行する

タイムアウトを「応答がなければ実行」の合図として使います。席にいれば止められて、いなければ予定どおり進みます:

```bash
result=$(yobirin --title "メンテナンス" --message "5分後にバックアップを開始します" \
  --action "今すぐ開始" --action "中止" --timeout 300)
case "$(echo "$result" | jq -r '.action // .result')" in
  中止) exit 0 ;;
  *) ./backup.sh ;;   # timeoutと「今すぐ開始」はどちらも実行へ
esac
```

## 動作要件

- macOS (Apple Silicon / Intel のユニバーサルバイナリ)
- Xcode Command Line Tools (ソースからビルドする場合のみ)

## インストール

### リリースバイナリから (ツールチェーン不要)

ビルド済みバイナリをダウンロードして、バイナリ自身にインストールさせます (privateリポジトリの間は [gh CLI](https://cli.github.com/) が必要です):

```console
$ gh release download --repo mjun0812/yobirin --pattern yobirin
$ chmod +x yobirin
$ ./yobirin install
```

`install` を実行すると、バイナリが自分自身を複製してad-hoc署名した `Yobirin.app` を組み立て、`~/Applications` へ配置し、コマンドを `~/.local/bin/yobirin` へsymlinkします。`~/.local/bin` をPATHに通しておいてください (配置先は `YOBIRIN_BIN_DIR` で変更できます)。ダウンロードしたファイルは、インストールが済めば削除して構いません。

### ソースから

```console
$ git clone https://github.com/mjun0812/yobirin.git
$ cd yobirin
$ swift build -c release
$ .build/release/yobirin install
```

アップグレードは `yobirin install` の再実行だけです。旧バンドルを削除してから新バンドルを配置するので、macOSに登録されるコピーは常に1つに保たれます。

## 通知の許可

初回実行時に「Yobirin」の通知許可ダイアログが表示されるので、**許可**を選んでください。

- ダイアログが表示されるのは、バンドルが `~/Applications` などの正規の場所にある場合だけです。インストーラがそこへ配置するので、通常は意識する必要はありません
- ダイアログの表示中、`--timeout` は進みません。タイマーが動き出すのは許可が確定してからです
- 許可されなかった場合 (後からオフにした場合を含む) は、JSONを出力せず、stderrへ理由を出して終了コード `2` で終了します。システム設定 > 通知 > Yobirin から再度オンにできます

## 使い方

```
yobirin --title <文字列> --message <文字列>
        [--subtitle <文字列>]
        [--group <id>]                 # 同じgroupの既存通知を置き換える
        [--timeout <秒>]               # 省略時は応答まで無期限に待つ
        [--action <ラベル>]...          # 複数指定可。2つ以上はドロップダウン表示になる
        [--reply]                      # テキスト入力アクションを追加する
        [--reply-placeholder <文字列>]  # 入力欄のplaceholder (--replyと併用)
        [--sound default|<名前>]
        [--image <パス>]               # 画像を添付する (既知の制限を参照)
```

`--timeout` には正の秒数を指定します。省略すると応答があるまで無期限に待つので、hookや自動化から呼ぶときは必ず指定してください。

### 出力

結果が確定すると、JSONオブジェクトを1つstdoutへ出力します:

```json
{"result":"clicked"}
{"result":"action","action":"承認","actionIndex":0}
{"result":"replied","text":"入力されたテキスト"}
{"result":"dismissed"}
{"result":"timeout"}
```

- `result`：`clicked`、`action`、`replied`、`dismissed`、`timeout` のいずれか
- `action` / `actionIndex`：押されたアクションボタンのラベルと0始まりのindex (同名ラベルはindexで区別できます)
- `text`：返信欄に入力されたテキスト

終了コード:

| コード    | 意味                                       | stdout              |
| --------- | ------------------------------------------ | ------------------- |
| 0         | ユーザーの応答またはタイムアウトを捕捉した | 結果JSON            |
| 2         | 通知の許可が得られていない                 | なし (理由はstderr) |
| その他非0 | 環境エラー (引数不正、添付の失敗など)      | なし                |

タイムアウトした通知は、通知センターから削除してから終了するので、応答されないまま残ることはありません。強制終了などで通知だけが残った場合も、引数なしで `yobirin` を起動すれば掃除されます。

### 待機中プロセスの一覧

いま何が応答を待っているのかは、`yobirin ps` で確認できます。`--timeout` を付け忘れて放置された通知を見つけるのに便利です:

```console
$ yobirin ps
PID    PROFILE    TITLE   TIMEOUT  ELAPSED
4211   (default)  Deploy  300      42s
4300   claude     Done    -        12m30s
```

`--json` を付けると機械可読な出力になります。

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
(default)  com.mjun0812.yobirin         0.4.1    /Users/you/Applications/Yobirin.app
claude     com.mjun0812.yobirin.claude  0.4.1    /Users/you/Applications/Yobirin-Claude.app
```

## 既知の制限

- `--image`：添付自体はmacOSに受理、保存されますが、現行のmacOSはバナーにも通知センターにもサムネイルを描画しません
- 通知バナーは、アプリアイコンの透過部分を白と合成して描画します。他のmacOSアプリと同様に、不透明な角丸タイルを背景に持たせ、透過はタイルの外側 (四隅) だけに留めたアイコンを使ってください
- インストール済みバンドルのアイコンを差し替えても、通知バナーに反映されるのはログアウトして再ログインした後です (通知ソースのアイコンをOSが強くキャッシュするため)。すぐ反映したい場合は、新しいプロファイル名でインストールしてください。アイコンが変わる上書きインストールでは、CLIがその場でこの案内を表示します
- macOS専用です。LinuxとWindowsに対応する予定はありません

## アンインストール

```console
$ rm -rf ~/Applications/Yobirin*.app
$ rm -f ~/.local/bin/yobirin*
```

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
