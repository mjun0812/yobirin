# Implementation Plan

- [ ] 1. Foundation: Swift Packageとビルド基盤
- [x] 1.1 Swift Packageのプロジェクト基盤を作成する
  - executableターゲットと引数パーサ依存、テストターゲットを持つパッケージ構成を作る
  - エントリポイントのstubを置き、ビルドとテスト実行が通る状態にする
  - `swift build` と `swift test` が成功する
  - _Requirements: 9.1_

- [x] 1.2 署名済み.appバンドルを組み立てるビルドスクリプトを作成する
  - 2アーキテクチャの個別ビルドとlipoによるユニバーサル化
  - Contents/{MacOS,Resources}の組み立てとInfo.plist (Bundle ID、LSUIElement=true) の配置
  - プレースホルダのアイコン元画像 (単色PNG等) をこのタスク内で生成して配置し、sips + iconutilでicnsを生成しバンドルへ焼き込む
  - ad-hoc署名 (制限付きentitlementなし) と、署名後のLaunchServices起動スモークテスト
  - スクリプト実行で署名済みバンドルが生成され、スモークテストが通る
  - _Requirements: 8.1, 8.2, 8.6, 9.1, 9.2, 9.3, 9.4_

- [ ] 2. Core: CLI・結果出力・通知セッション
- [x] 2.1 (P) CLIオプションのパースと通知リクエストの組み立てを実装する
  - --title / --message を必須とし、--subtitle / --group / --timeout / --action (複数可) / --reply (placeholder任意) / --sound / --image を受け付ける
  - パース結果を通知リクエストのモデルへ変換する。--icon に相当するオプションは提供しない
  - 必須欠落・不正値がエラーになり、各オプションの反映がunitテストで確認できる
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 4.1, 4.3, 5.1, 5.3_
  - _Boundary: YobirinCommand_

- [x] 2.2 (P) 結果JSONの生成と終了コード決定を実装する
  - 5種の結果 (clicked / action / replied / dismissed / timeout) それぞれのJSON (action / actionIndex / text / deliveredAt) を生成する
  - ユーザー応答はJSON + exit 0、許可なしはstderr + exit 2、環境エラーはJSONなし + 非0という区別を実装する
  - 各結果種別のJSON内容と終了コード分岐がunitテストで通る
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 7.2, 7.3_
  - _Boundary: ResultEmitter_

- [x] 2.3 通知の配信と応答捕捉を実装する
  - customDismissAction付きcategoryを呼び出しごとに動的登録し、actionは yobirin-action-\<index\>、replyはテキスト入力アクションとして登録する
  - --group指定時は同一identifierの配信済み通知を除去してから配信する
  - delegateコールバックで clicked / dismissed / action / replied を判別し、結果を確定する
  - 結果確定はロックまたはactorで一度きりを保証し、ポーリングは使わない
  - 通知センターへの依存はプロトコルで抽象化する (署名済みバンドル外のswift testでは実センターが例外死するため、テストはモックに対して行う)
  - 応答種別ごとの結果確定と二重確定の防止がモックを使ったテストで確認できる
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 3.1, 3.2, 3.3, 3.4, 3.5, 3.7, 3.8, 4.1, 4.2, 4.3, 4.4_

- [ ] 3. Core: アプリライフサイクルと権限フロー
- [x] 3.1 認可フローとタイムアウト制御を実装する
  - NSApplication + AppDelegate方式で起動し、認可完了後に通知配信とタイムアウトタイマーを開始する
  - 許可なし (エラー / granted == false の両経路) はstderrへ理由を出してexit 2で終了する
  - タイムアウト確定時は配信済み通知を削除してから結果を出力する。--timeout省略時は無期限に待機する
  - 許可なし環境での実行がexit 2 + stderrになり、認可後にのみタイマーが動くことを確認できる
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 7.1, 7.2, 7.3_

- [x] 3.2 終了処理とアプリ再起動への防御を実装する
  - 結果出力後に0.5〜1秒の遅延を置いて終了する
  - 引数なし起動時は通知を出さず、応答待ちの主がいない配信済み通知を掃除して即終了する
  - 応答の受け付けをプロセス生存中に限定する
  - 引数なし起動が通知ゼロで即終了することを確認できる
  - _Requirements: 5.5, 6.1, 6.2, 6.3_

- [ ] 4. Integration: 配線・インストール・プロファイル
- [x] 4.1 全コンポーネントを結線してバンドルから動作させる
  - 引数パース → 認可 → group置換 → category登録 → 配信 → 応答/タイマー → JSON出力 → 遅延exit の一連のフローを結線する
  - 初回は許可ダイアログへの手動応答が必要 (以降は自動で確認できる)
  - ~/Applications配置のバンドルをsymlink経由で直接実行し、timeout経路で結果JSONがstdoutへ返りexit 0となる
  - _Requirements: 3.6, 8.3_

- [x] 4.2 インストールとアップグレードの処理を実装する
  - バンドルの~/Applicationsへの配置とPATHへのsymlink作成
  - アップグレード時に同一Bundle IDの旧バンドルを確実に削除する
  - インストール後にPATH上のコマンドで通知が出せ、再インストールで旧バンドルが残らない
  - _Requirements: 8.3, 8.4, 8.5_

- [x] 4.3 アイコンプロファイルの派生バンドルを実装する
  - アイコンとBundle IDのみ差し替えた派生バンドルをビルドできるようにする
  - プロファイル選択機構 (プロファイルごとのsymlink、または--profileによる薄いディスパッチ) を確定して実装する
  - 2つのプロファイルが並存し、それぞれのアイコンと名義で通知が配信される
  - _Requirements: 10.1, 10.2, 10.3_

- [ ] 5. Validation: テストと手動検証
- [x] 5.1 結合的な自動テストを整備する
  - group置換の呼び出し順 (除去 → 配信)、timeout確定時の削除 → 出力 → 遅延 → 終了の順序、応答とタイマー競合時の一度きり出力をテストする
  - テストは2.3で導入した通知センターのモックに対して行う (実センターはバンドル外で例外死するため)
  - `swift test` で全テストが通る
  - _Requirements: 2.1, 3.8, 5.2, 6.1_
  - _Depends: 2.3_

- [x] 5.2 手動検証: 通知表示と応答検知
  - 通知の表示とバンドルアイコンの反映、クリック / 却下 / アクション / reply それぞれの検知を実機で確認する
  - 複数インスタンス並行実行で、操作したインスタンスにのみ応答が届くことを確認する
  - 各応答種別で期待どおりの結果JSONがstdoutへ返ることが記録されている
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 3.1, 3.2, 3.3, 3.4, 3.5, 3.8, 4.1, 4.3_

- [x] 5.3 手動検証: 通知許可フロー
  - 初回の許可ダイアログが正規の場所への配置で表示されること、ダイアログ表示中はタイムアウトが進まないことを確認する
  - 許可拒否時にJSONなしでexit 2となりstderrに理由が出ることを確認する
  - 許可フローの各確認項目の結果が記録されている
  - _Requirements: 5.4, 7.1, 7.2_

- [x] 5.4 手動検証: ライフサイクルと再起動防御
  - 引数なし起動が通知ゼロで即終了し、孤児通知が掃除されることを確認する
  - 結果出力後の遅延exitにより再起動由来の余計な通知が出ないこと、timeout後に通知が残らないことを確認する
  - ライフサイクル系の各確認項目の結果が記録されている
  - _Requirements: 5.1, 5.2, 5.5, 6.1, 6.2, 6.3_

- [x] 5.5 手動検証: アイコンプロファイルの独立性
  - 各プロファイルで初回許可ダイアログが独立に表示され、それぞれのアイコン・名義で通知が配信されることを確認する
  - システム設定の通知一覧にプロファイルごとの項目が並び、片方だけオフにできることを確認する
  - プロファイル系の各確認項目の結果が記録されている
  - _Requirements: 10.2, 10.3_

- [ ] 6. Core: サブコマンド構造と起動ゲート
- [x] 6.1 通知センター抽象の遅延評価化とバンドル判定を実装する
  - 通知センター抽象の実アダプタを、型に触れただけではセンターへアクセスしない遅延評価へ改める
  - バンドル内/外の判定を注入可能なヘルパとして追加する (起動ゲートのテスト可能性の前提)
  - バンドル外相当の環境でアダプタ型を参照してもクラッシュしないことがテストで確認できる
  - _Requirements: 12.1_
  - _Boundary: NotificationCenterClient, Yobirin (起動ゲート)_

- [x] 6.2 サブコマンド構造へ再編し既存呼び出しの互換を保つ
  - ルートコマンドをサブコマンド構成にし、通知送信を既定サブコマンドへ分離する
  - `yobirin --title <str> --message <str> ...` の従来形式がそのまま通知送信へ解決される
  - 既存の全テストがgreenのまま、互換を検証するテストが追加されている
  - _Requirements: 11.8_

- [ ] 6.3 起動ゲートを再構成してバンドル外でも安全にする
  - 判定を「バンドル外検知 → バンドル内なら引数なしガード→ルーティング / バンドル外ならコマンド種別で分岐」の構造へ変更する
  - バンドル外での通知系要求・引数なし起動は、インストール案内をstderrへ出して非0で終了する (クラッシュしない)
  - バンドル外でもインストール系とヘルプは続行される
  - ゲートの分岐 (バンドル内外 × コマンド種別) がテストで確認できる
  - _Requirements: 12.1, 12.2, 12.3_

- [ ] 7. Core: プロファイルディスパッチとインストーラ部品
- [ ] 7.1 (P) プロファイル規約とディスパッチを実装する
  - プロファイル名からバンドル名・Bundle ID・配置パスを導出する規約を単一ソース化する (`^[a-z0-9]+$` 検証込み)
  - `--profile` 指定時に対象バンドルのMach-Oへ実行を引き継ぐ (引数から `--profile` を除いて透過する)
  - 対象バンドル未インストール時はJSONなし・stderr・非0で終了する
  - exec引数の構築と未インストール分岐がモックを使ったテストで確認できる
  - _Requirements: 10.4, 10.5_
  - _Boundary: ProfileDispatch_

- [ ] 7.2 (P) icns生成と同梱標準アイコンを実装する
  - ImageIOでアイコンPNGからicnsを生成する (各サイズにDPIメタデータ 1x=72/2x=144 を付与)
  - 標準アイコン (鈴) のバイト列を生成済みソースとして同梱する (外部ファイル非依存。再生成手順をコメントに残す)
  - 生成したicnsを読み戻し、10スロット (1x/2x×5サイズ) が存在することがテストで確認できる
  - _Requirements: 11.3, 11.4_
  - _Boundary: IcnsWriter, DefaultIcon_

- [ ] 7.3 インストーラ本体を実装する
  - 実行中の自分自身のバイナリを解決してバンドルへ複製し、Info.plist (Bundle ID・名前・Dock非表示・バージョン) を生成する
  - アイコン (指定パスまたは同梱標準) をicnsとして焼き込み、外部codesignでad-hoc署名する (失敗は非0)
  - 配置は固定パス検証 → 旧バンドル削除 → コピー → symlink張り替え (非symlink実ファイルは非破壊で中断) の順で行う
  - 配置後に署名検証と配置済みコマンドの実行確認を行い、失敗は非0で終了する
  - 通知APIの型に一切触れない
  - 組み立て内容・配置計画・失敗分岐がテンポラリ領域でのテストで確認できる
  - _Requirements: 8.4, 8.5, 9.4, 11.1, 11.2, 11.3, 11.5, 11.6, 11.7, 11.9, 12.1_
  - _Depends: 7.1, 7.2_

- [ ] 8. Integration: 結線と配布経路の置き換え
- [ ] 8.1 installサブコマンドを結線し、バンドル組み立てを一元化する
  - `install [--profile <name>] [--icon <path>]` の引数定義をルートへ登録し、インストーラと結線する
  - scripts/build-app.sh と scripts/install.sh を削除する (組み立て実装はCLIの1箇所のみになる)
  - scripts/ の消滅に伴い、ci.yml のlintジョブからシェルスクリプト解析ステップ (shellcheck / shfmt) を除去する (oxfmtチェックとビルド・テストジョブは無変更)
  - ソースからのビルド後に `.build/release/yobirin install` が完走し、symlink経由で `--help` が動く。調整後のCIがgreenである
  - _Requirements: 9.1, 9.3, 11.1_

- [ ] 8.2 素のバイナリからのブートストラップを実機で確認する
  - リリース添付のユニバーサル実行ファイル (または同等の素バイナリ) だけで install → timeout経路の通知が完走する
  - `install --profile <name> --icon <path>` で派生バンドルが入り、`--profile <name>` でそのアイコン・名義の通知が出る (初回は許可ダイアログへの手動応答が必要)
  - 素のバイナリの引数なし起動・通知要求が案内 + 非0で終了し、クラッシュレポートが生成されない
  - リリースワークフローがテスト合格後にユニバーサルバイナリを添付していることを確認する
  - _Requirements: 9.2, 10.1, 10.2, 12.2, 12.3, 13.1, 13.2, 13.3_

- [ ] 9. Validation: テストと手動検証の追補
- [ ] 9.1 結合自動テストを拡充する
  - 起動ゲートの分岐マトリクス (バンドル内外 × 通知系/インストール系/引数なし) を結合レベルで検証する
  - installの失敗系 (アイコンパス不在、非symlink実ファイル衝突、署名失敗) が非0 + stderrで終了することを検証する
  - `swift test` で全テストが通る
  - _Requirements: 11.6, 11.9, 12.1_

- [ ] 9.2 手動検証チェックリストを追補して実施する
  - manual-verification.md にブートストラップ・バンドル外安全性・`--profile` 配信の項目を追加して実施する
  - 全項目の実施結果が記録されている
  - _Requirements: 10.2, 10.3, 12.2, 12.3, 13.2_

## Implementation Notes

- 1.2: ユーザーのグローバルgitignoreの `Icon` パターンがcase-insensitive FSで `assets/icon/` にマッチする。プロジェクト .gitignore の `!assets/icon/` で打ち消し済み。今後 assets/icon/ 配下へファイルを足すタスク (4.3等) はこの前提でよい
- 1.2: ビルド成果物は `.build/app/Yobirin.app`。スモークテストは entitlement起因の起動不能 (Launchd job spawn failed) をexit非0で検出できることを破壊テストで確認済み
- 2.1: `--reply [placeholder]` はswift-argument-parserの制約により `--reply` (Flag) + `--reply-placeholder <str>` の2オプション構成に変更 (design.md/requirements.md追従更新済み)。`--timeout` はDouble型 (TimeInterval互換)。通知リクエストモデルは `NotificationRequest` (Sources/yobirin/NotificationRequest.swift)
- 2.1: 負値オプションのテストは `--timeout=-1` の `=` 構文が必要 (スペース区切りだとArgumentParser自体が弾き、自前バリデーション経路を検証できない)
- 2.3: 通知センターは `NotificationCenterClient` プロトコルで抽象化 (実アダプタ: `UNNotificationCenterAdapter`)。応答判別はUN型を含まない `handleResponse(actionIdentifier:userText:)` で受ける。replyのidentifierは `yobirin-reply`
- 2.3: **4.1の配線時の注意**: `NotificationSession` のコンストラクタ引数 `actions` は `request.actions` と同一の配列を渡すこと (categoryビルドと応答→label復元が別経路のため、不一致だとaction結果が壊れる)。`getDeliveredNotifications` はプロトコルに先行宣言済み (3.2の孤児掃除用)
- 3.1: オーケストレーションは `AppFlow` (認可→配信→タイマー→出力決定)。タイマーはScheduler注入で抽象化。timeout時の通知削除は `NotificationSession.commit` の一度きり機構内で実施。認可optionsは `[.alert, .sound]`
- 3.1: レビュー提案: AppFlowレベルで「deliver throw→環境エラー出力」の結合テストを5.1で1本追加すると堅牢 (現状は各部品の単体テストでカバー)
- 3.2: 遅延exitは `ExitCoordinator` (delay=1.0秒定数)、引数なしガードは `LaunchGuard.isArgumentlessLaunch` + `cleanUpAndExit` (掃除完了後にexit 0、遅延なし)。4.1はこの2部品を結線する
- 3.2: `UNNotification` はSDK上init不可でテストfixtureを作れない。孤児掃除の複数通知ケースは手動検証5.4で確認する。レビュー提案: LaunchGuardTestsのMockNotificationCenterClientにロックまたは安全性コメントを追加 (非ブロッキング)
- 4.1: 結線完了、timeout経路のe2e実証済み ({"result":"timeout"} + exit 0)。`~/Applications/Yobirin.app` 配置済み、scratchにsymlinkあり。通知許可は付与済み環境
- 4.1: Yobirin.swiftの `NSApplication` 操作にmain actor警告3件 (Swift 6 isolation checking)。@MainActor付与はParsableCommand準拠と衝突しビルドが壊れるためFYIとして残置 (CLIエントリはmain thread実行で実行時リスクなし)。将来Swift toolchainがエラー化したら @preconcurrency 等で対処
- 4.2: インストールは `scripts/install.sh` (常時ビルド→旧バンドル削除→~/Applications配置→`~/.local/bin/yobirin` symlink。`YOBIRIN_BIN_DIR` で変更可)。BIN_DIRに非symlink実ファイルがあると非破壊で中断する。`.build/app/` のLaunchServices登録リスクは未対処 (既知)
- 4.3: プロファイル選択は「プロファイルごとのsymlink」方式に確定 (design.md更新済み)。`install.sh claude codex` で Yobirin-Claude.app / Yobirin-Codex.app + `yobirin-claude` / `yobirin-codex` symlinkを配置。プレースホルダアイコンのみ (実ロゴ未使用)
- 5.4: **手動検証でバグ発見→修正 (commit 28fb36a)**: cleanUpAndExitが非同期掃除の完了を待たずreturnし、completion実行前にプロセスがexitして孤児掃除が機能していなかった。教訓: 「completionを待つ構造のモックテスト」は「実プロセスが待たずに死ぬ」バグを検出できない。exit系の非同期APIは「呼び出しがreturnする前に完了しているか」をテストすること
- 5.2〜5.5: 手動検証全18項目pass (2026-07-27、記録は manual-verification.md)
- 6.1: `swift test` のxctestホストは `Bundle.main.bundleIdentifier` が非nil ("com.apple.dt.xctest.tool")。**6.3の起動ゲートテストは既定値に頼らず必ずbundleIdentifierを注入して「バンドル外」を明示的にシミュレートすること**。バンドル判定は `BundleEnvironment.isOutsideBundle(bundleIdentifier:)`
- 最終検証: `--image` の添付はOS受理まで機能するが、**macOS 26はサムネイルをバナー・通知センターとも描画しない** (画像サイズ・配置場所を変えて再現)。OS挙動の既知制限としてREADME (M4 OSS化時) に記載すること。LSUIElement=trueはInfo.plistの検証 (plutil) で確認済み (Dock非表示の目視は未取得だが、多数の検証実行中にDock表示の報告なし)
- アイコン更新 (2026-07-27): 既存Bundle IDのバンドルアイコンを差し替えた場合、通知バナーのアイコンは**ログアウト/ログインまで反映されない** (実測: usernotificationsd/NotificationCenterの再起動・`lsregister -f` はいずれも無効、再ログインで反映)。Finder上のアイコンは即時反映される。新しいBundle ID (新プロファイル名) なら初回から新アイコンで表示されるため、アイコン検証時はプロファイル名を変えると速い
- アイコン設計 (2026-07-27、M3統合時に判明): **通知バナーはアプリアイコンの透過部分を白で合成する**。画像データ・icns・LaunchServicesが返すアイコンのいずれもalpha=0.0を保っているが表示側で白が敷かれる (alerterの `--app-icon` は私用APIで「通知の画像」として渡すため透過が活きていた)。対策は不透明な角丸タイル背景の焼き込み。**背景はキャンバス全面 (0..1024) に敷く** — 角丸タイル (100..924) だけに敷くと、はみ出したロゴの透過部分が白く合成される
