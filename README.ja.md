# yobirin

**yobirin** (呼び鈴) は、鳴らして応答を待つmacOS向けの通知CLIである。

通知を1件配信し、ユーザーの反応 (クリック、却下、アクションボタン、テキスト返信、タイムアウト) を同期的に待って、結果をJSONとしてstdoutへ出力して終了する。
これにより、シェルスクリプトやツールのhookから「通知への反応」を扱えるようになる。

[English README is here](README.md)

```console
$ yobirin --title "Deploy" --message "リリースを承認しますか?" --action "承認" --action "却下" --timeout 60
{"result":"action","action":"承認","actionIndex":0}
```

## なぜ作ったか

既存のmacOS通知CLIは、反応を捕捉できないか (terminal-notifierは通知を出すだけ)、非推奨の `NSUserNotification` APIの上で却下をポーリング検知しており、通知を放置するとメモリが増え続ける (alerter)。

yobirinは現行の `UserNotifications` frameworkだけを使う。
却下はdelegateコールバック (`customDismissAction`) で検知するため、ポーリングループが存在せず、待機中にCPUもメモリも消費しない。
通知はyobirin自身の名義で配信し、他アプリへのなりすましは行わない。

## 動作要件

- macOS (Apple Silicon / Intel のユニバーサルバイナリ)
- Xcode Command Line Tools (ソースからのビルドに必要)

## インストール

```console
$ git clone https://github.com/mjun0812/yobirin.git
$ cd yobirin
$ bash scripts/install.sh
```

インストーラはユニバーサルバイナリをビルドし、ad-hoc署名した `Yobirin.app` を `~/Applications` へ配置して、コマンドを `~/.local/bin/yobirin` へsymlinkする (`~/.local/bin` をPATHに通すか、`YOBIRIN_BIN_DIR` で配置先を変更する)。

再実行すればそのままアップグレードになる。
旧バンドルを削除してから新バンドルを配置するため、macOSに登録されるコピーは常に1つに保たれる。

## 通知の許可

初回実行時に「Yobirin」の通知許可ダイアログが表示されるので、**許可**を選ぶ。

- ダイアログはバンドルが `~/Applications` などの正規の場所にある場合にだけ表示される (インストーラが配置するので通常は意識しなくてよい)。
- ダイアログの表示中は `--timeout` が進まない。タイマーは許可の確定後に開始される。
- 許可されなかった場合 (後からオフにした場合を含む)、yobirinはJSONを出力せず、stderrへ理由を出して終了コード `2` で終了する。再度有効にするには、システム設定 > 通知 > Yobirin をオンにする。

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

`--timeout` には正の秒数を指定する。
省略すると応答があるまで無期限に待つため、hookや自動化から呼ぶ場合は必ず明示的に指定する。

### 出力

結果が確定すると、JSONオブジェクトを1つstdoutへ出力する:

```json
{"result":"clicked"}
{"result":"action","action":"承認","actionIndex":0}
{"result":"replied","text":"入力されたテキスト"}
{"result":"dismissed"}
{"result":"timeout"}
```

- `result`：`clicked`、`action`、`replied`、`dismissed`、`timeout` のいずれか
- `action` / `actionIndex`：押されたアクションボタンのラベルと0始まりのindex (同名ラベルはindexで区別できる)
- `text`：返信欄に入力されたテキスト

終了コード:

| コード    | 意味                                       | stdout              |
| --------- | ------------------------------------------ | ------------------- |
| 0         | ユーザーの応答またはタイムアウトを捕捉した | 結果JSON            |
| 2         | 通知の許可が得られていない                 | なし (理由はstderr) |
| その他非0 | 環境エラー (引数不正、添付の失敗など)      | なし                |

スクリプトからは `jq -r '.result'` で分岐する:

```bash
result=$(yobirin --title "ビルド完了" --message "ログを開きますか?" --timeout 300)
case "$(echo "$result" | jq -r '.result')" in
  clicked) open build.log ;;
  timeout|dismissed) ;;
esac
```

タイムアウト時は、配信済みの通知を通知センターから削除してから終了するため、応答されない通知が残らない。
引数なしで `yobirin` を起動すると、強制終了などで残った孤児通知を掃除して静かに終了する。

## アイコンプロファイル

通知のアイコンはアプリバンドルのアイコンに固定される (macOSの制約で、通知ごとのアイコン指定は存在しない)。
用途別にアイコンを使い分けたい場合は、アイコンとBundle IDだけが異なる派生バンドルをインストールする:

```console
$ bash scripts/install.sh claude codex
```

これで `Yobirin-Claude.app` と `Yobirin-Codex.app` が `assets/icon/<name>.png` のアイコンで配置され、コマンド `yobirin-claude` と `yobirin-codex` が作られる。
各プロファイルは初回に独立して通知許可を求め、システム設定にも別項目として並ぶため、プロファイル単位でオンオフできる。

## 既知の制限

- `--image`：添付自体はmacOSに受理・保存されるが、現行のmacOSはバナーにも通知センターにもサムネイルを描画しない。
- インストール済みバンドルのアイコンを差し替えた場合、通知バナーへの反映はログアウトして再ログインするまで行われない (通知ソースのアイコンがOSに強くキャッシュされるため)。
- macOS専用。LinuxとWindowsへの対応予定はない。

## アンインストール

```console
$ rm -rf ~/Applications/Yobirin*.app
$ rm -f ~/.local/bin/yobirin*
```

## 開発

```console
$ swift test              # ユニットテストと結合テスト (通知センターはモック)
$ bash scripts/build-app.sh [profile]   # 署名済み.appバンドルのビルド
$ prek install            # pre-commit hookの有効化 (swift format / shfmt / shellcheck / oxfmt)
```

CI (GitHub Actions) は `main` へのpushとpull requestで、ビルド、テスト、lintを実行する。

通知の表示、対話、許可フローはGUIに依存するため自動テストでは検証できない。
specと手動検証チェックリストは `.kiro/specs/yobirin-cli/` に、設計の経緯と実測記録は `docs/design-research.md` にある。

## ライセンス

[MIT](LICENSE)

## 参考リンク

- [vjeantet/alerter](https://github.com/vjeantet/alerter)：yobirinの設計の下敷きになった対話捕捉型の通知CLI。非推奨 `NSUserNotification` API上のポーリング却下検知によるメモリリークが、本ツールを作る動機になった。
- [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier)：alerterのfork元である古典的なmacOS通知CLI。
- [777genius/claude-notifications-go / swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier)：XcodeプロジェクトなしにSwift Packageから署名済み `.app` バンドルを組み立てる方法の参考実装。
- [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications)：設計時に参照した、活発にメンテナンスされているSwift + `UserNotifications` 実装。
- [Apple: UserNotifications framework](https://developer.apple.com/documentation/usernotifications)：yobirinが使っている通知API。
