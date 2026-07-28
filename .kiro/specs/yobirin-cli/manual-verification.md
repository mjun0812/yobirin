# 手動検証チェックリスト

実施日: 2026-07-27 (5.2〜5.5)、2026-07-28 (8.2/9.2)
環境: macOS 26 / Darwin 25、`~/Applications/Yobirin.app` + `~/.local/bin/yobirin` (許可付与済み)

結果は各項目の `[ ]` を `[x]` にし、備考欄に観測内容を記す。失敗した場合は `[!]` にして内容を記録する。

## 5.2 通知表示と応答検知

- [x] 通知が表示され、バンドルアイコン (プレースホルダ単色) が反映されている
- [x] クリック検知: `{"result":"clicked"}` + exit 0 を確認
- [x] 却下検知: バナーの×操作で `{"result":"dismissed"}` + exit 0 を確認
- [x] action検知: `--action OK --action Open` でOpen選択 → `{"result":"action","action":"Open","actionIndex":1}` を確認
- [x] reply検知: 日本語入力「あいうえお」が `{"result":"replied","text":"あいうえお"}` として往復することを確認
- [x] 複数インスタンス並行実行: Aのみクリック → Aは `clicked`、Bは影響を受けず独立に `timeout` (両方exit 0)
- [x] group置換: 同一group 2連発で1件目が2件目に置き換わり、同時には1件のみ表示されることを目視確認

- [x] 画像添付 (`--image`): 添付はOSに受理される (添付ファイルが通知ストアへ移動される証跡を4回確認、unitテストで `content.attachments == 1` を検証)。**ただしmacOS 26ではバナー・通知センターのいずれもサムネイルを描画しない** (2048px/256px、複数の配置場所で再現)。実装欠陥ではなくOS側のレンダリング挙動として記録

備考: 全項目pass (2026-07-27実施)。timeout後に通知センターへ通知が残らないことも同時に目視確認済み。--imageのサムネイル非描画はOS挙動の既知制限。

## 5.3 通知許可フロー

前提: このマシンのデフォルトBundle IDは許可済みのため、初回ダイアログの確認は未許可のプロファイル (5.5のClaude/Codex) で行うのが効率的。拒否テストはシステム設定で一時的にオフにして行う。

- [x] 初回の許可ダイアログが表示される (Yobirin-Claude / Yobirin-Codex の初回実行でそれぞれ独立に表示)
- [x] ダイアログ表示中は `--timeout` が進まない (`--timeout 5` の実行が2分14秒 — 許可後にのみカウント開始することを実測)
- [x] 許可拒否状態で実行 → JSONなし、stderrに `UNErrorDomain Code=1` の理由、exit 2 (Yobirin-Claudeをシステム設定でオフにして確認)

備考: 3/3項目pass (2026-07-27)。

## 5.4 ライフサイクルと再起動防御

- [x] 引数なし起動 (`yobirin`) が通知ゼロで即終了する (exit 0、修正後0.05秒)
- [x] 孤児通知の掃除: 初回検証で**失敗** → 根本原因 (cleanUpAndExitが非同期掃除の完了を待たずreturnし、completion実行前にプロセスがexit) を特定し修正 (commit 28fb36a)。再検証でSIGKILL孤児が引数なし起動で消えることを目視確認
- [x] 遅延exit: 全検証を通してクリック応答後の余計な通知の再出現なし (ユーザー確認)
- [x] timeout後に通知が通知センターに残らない (5.2実施時に確認済み)

備考: 4/4項目pass (2026-07-27)。孤児掃除バグはモックが「completionを待つテスト構造」だったため単体テストをすり抜けていた。回帰テスト2件を追加済み。

## 5.5 アイコンプロファイルの独立性

- [x] `yobirin-claude` 初回実行 → Claude用の独立した許可ダイアログ → 許可 → オレンジ系アイコン・"Yobirin-Claude" 名義で表示
- [x] `yobirin-codex` も同様に独立して許可・表示 (紫系アイコン・"Yobirin-Codex" 名義)
- [x] システム設定 > 通知 に Yobirin / Yobirin-Claude / Yobirin-Codex が別項目で並ぶ
- [x] Yobirin-Claudeだけオフ → claudeは exit 2、デフォルトYobirinは正常動作 (独立制御を確認)

備考: 4/4項目pass (2026-07-27)。検証後にYobirin-Claudeの通知はオンへ戻す (ユーザー操作)。

## 8.2/9.2 ブートストラップとバンドル外安全性

前提: 素バイナリは `swift build -c release` の成果物をダウンロード相当の場所 (テンポラリ領域) へ複製して使用 (公開済みv0.1.0添付バイナリは `install` 実装前のため対象外。次回リリースで置き換わる)。

### バンドル外安全性 (Requirement 12)

- [x] 素のバイナリの引数なし起動 → 案内メッセージ + exit 1
- [x] 素のバイナリの通知要求 (`--title`/`--message`) → 案内メッセージ + exit 1
- [x] 上記実行後にクラッシュレポートが生成されない (DiagnosticReportsのyobirin関連は修正前の既存2件のまま増加なし)

### ブートストラップ (Requirement 11, 13)

- [x] ダウンロード相当の場所の素バイナリから `install` が完走 (exit 0、`~/Applications/Yobirin.app` 置換 + symlink維持)
- [x] symlink経由のtimeout通知が完走: `{"result":"timeout"}` + exit 0
- [x] symlink経由の引数なし起動が孤児掃除経路で exit 0
- [x] リリースワークフローが `swift test` 合格後にユニバーサルバイナリを添付する構成 (release.yml、v0.1.0の `yobirin-universal` アセットで実績確認)

### `--profile` 配信 (Requirement 10, 11)

- [x] `install --profile test --icon <PNG>` で `Yobirin-Test.app` (Bundle ID `com.mjun0812.yobirin.test`)・カスタムicns焼き込みを確認。symlinkはデフォルトを指したまま不変
- [x] `--profile test` の初回実行 → 独立した許可ダイアログ → 許可 → 指定アイコン・"Yobirin-Test" 名義で通知表示 (`{"result":"timeout"}` + exit 0、名義・アイコンはユーザー目視確認。2026-07-28)
- [x] 検証後のクリーンアップ: `Yobirin-Test.app` の削除 (システム設定 > 通知の項目はOS側の整理待ちで残存し得る)

備考: 検証中に発見・修正したバグ1件 — symlink経由起動がバンドル外と誤判定され通知系が案内+exit 1になるリグレッション (CFBundleが実行パスのsymlinkを解決しないため。実体パスへの再execで修正、commit a868bef。回帰テストを純粋関数3件 + プロセス結合1件追加済み)。

## 13.2 透過ディスパッチ

前提: デフォルトバンドルインストール済み・PATH上に素のバイナリ (symlink経由) がある状態で確認する。

- [x] PATH上の素のバイナリ経由での通知要求が、インストール済みデフォルトバンドルへ引き継がれて実際に通知配信される (テンポラリ配置の素バイナリ → `{"result":"timeout"}` + exit 0。2026-07-28)
- [x] 引数なし起動 (素のバイナリ経由) が孤児掃除の引き継ぎとして機能する (exit 0で即終了)
- [x] 引き継ぎ元バイナリとインストール済みバンドルのバージョンを意図的に不一致にし、stderrへ更新案内が表示されることを目視確認 (`YOBIRIN_HOME` の偽バンドル (0.0.1) に対し `note: installed bundle is 0.0.1 but this binary is 0.4.1; run 'yobirin install' to update` を確認。同時にechoスタブへの引数透過も確認)

## 総括

- 5.2〜5.5の全18項目pass (2026-07-27)
- 検証中に発見・修正したバグ1件: 孤児通知掃除が非同期完了を待たずexitしていた (commit 28fb36a で修正、回帰テスト追加済み)
- 8.2/9.2 (2026-07-28): 全10項目pass (`--profile` 初回許可ダイアログ〜表示確認はユーザー参加で実施)。発見・修正したバグ1件: symlink起動の誤判定リグレッション (commit a868bef)
- 13.2 (2026-07-28): 透過ディスパッチ全3項目pass (素バイナリからの引き継ぎ配信・掃除引き継ぎ・バージョン不一致案内の目視)
