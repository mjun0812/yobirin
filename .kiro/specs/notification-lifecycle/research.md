# Research & Discovery Log: notification-lifecycle

_実施日: 2026-07-31 / ディスカバリ種別: Light (既存システムの拡張)。コードベースは cli-arguments-ux 実装時の知識を引き継ぐ_

## D1. 設計上の主要判断

### DD-1: identifier の一致規則 — group を符号化してから接頭辞に使う

**問題**: Req 1.4 (先頭部分が一致する別 group を誤削除しない) は、素朴な「`group + 区切り文字` の前方一致」では満たせない。`--group` は任意の文字列なので、group 自体に区切り文字が含まれると衝突が再発する (例: 区切りを `#` とした場合、group `a` の走査接頭辞 `a#` は group `a#b` の identifier `a#b#<uuid>` にも一致する)。

**決定**: identifier を `base64(utf8(group)) + "#" + UUID` とする。一致の正確さを担保しているのは **`#` 終端**である: Base64 のアルファベット (`A-Za-z0-9+/=`) は `#` を含まないため、走査接頭辞 `base64(g1) + "#"` が別 group の識別名 `base64(g2) + "#" + UUID` に一致するには `base64(g2)` の内部に `#` が現れる必要があり、これは起こり得ない。なお「Base64 が単射だから符号化結果同士が接頭辞関係にならない」は**誤り** — `base64("abc") = YWJj` は `base64("abcd") = YWJjZA==` の接頭辞である (2026-07-31 実証)。単射性ではなく `#` 終端とアルファベット排他が本質であり、テスト (task 1.1) はこのケース (`abc` と `abcd`) を不変条件の検証に含めること。

- group 未指定の identifier は従来どおり UUID 単体。UUID の文字集合 (`0-9a-f-`) は `#` を含まないため、走査接頭辞と衝突しない
- 部分エスケープ (percent-encoding) 案は、エスケープ漏れのバグ余地があるため不採用。Base64 は全量変換で考慮漏れが構造的に起きない
- identifier は外部契約ではない (ユーザーから見えない内部名)。可読性の低下はデバッグ時のみの影響

### DD-2: `NotificationCenterClient` の配信済み一覧を identifier 列へ変更する

**問題**: group 置換の走査をテストするには、モックが配信済み通知を返せる必要がある。しかし現在のプロトコルは `getDeliveredNotifications(completionHandler: ([UNNotification]) -> Void)` で、`UNNotification` は SDK 制約によりテストコードから構築できない (LaunchGuardTests に既記録の制約。これまでモックは空配列しか返せなかった)。

**決定**: プロトコルのメソッドを `getDeliveredNotificationIdentifiers(completionHandler: ([String]) -> Void)` へ置き換える。実アダプタが `UNNotification → identifier` の写像を担い、モックは任意の文字列列を返せるようになる。

- 既存の利用箇所は `LaunchGuard` (掃除) のみで、そこでも identifier しか使っていないため、置き換えで失うものがない
- 副次効果: LaunchGuardTests の「空配列以外のフィクスチャを注入できない」という既存の検証制約が解消される

### DD-3: キャンセルの経路はタイムアウトと同型にする

**決定**: SIGTERM → `NotificationSession.handleCancel()` → `commit(.canceled)`。`commit` は timeout と同様に「自分の identifier の通知を削除してから `onResult`」を実行する (削除対象の条件を `.timeout` から「`.timeout` または `.canceled`」へ広げる)。

- 一度きり確定 (`committedLock`) をそのまま使うため、応答・タイムアウト・キャンセルの競合は既存の排他で先着が勝つ (Req 2.4)
- 出力経路も既存と同一 (`ResultEmitter.forResult` → `ExitCoordinator.finish` → 1秒遅延 exit)。「削除 → 出力 → 遅延 exit」の順序保証はタイムアウト経路で手動検証済みの実績に乗る (Req 2.3)

### DD-4: 配信前キャンセル (Req 2.5) は `deliver` 側のガードで守る

**問題**: SIGTERM が通知許可の要求中に届くと、キャンセル確定後に認可コールバックが `deliver` を呼び、誰も後始末しない通知が配信されてしまう。

**決定**: `NotificationSession.deliver` に「結果確定済みなら配信しない」ガードを追加する。シグナル側・認可側のどちらの順序で走っても、確定後の配信が構造的に起きない。

### DD-5: シグナル受信の実装方式

`signal(SIGTERM, SIG_IGN)` + `DispatchSource.makeSignalSource(signal:queue:)` (main queue)。NSApplication のランループと共存する標準パターン。シグナルハンドラの async-signal-safety 問題を避けられる (ハンドラ内で任意コードを実行できるのは DispatchSource 側)。ソースはプロセス生存中保持する。

- 登録は `NotifyCommand.run()` の通知系経路の冒頭 (認可要求より前) に置く。これで「配信前の受信」(Req 2.5) も取りこぼさない
- SIGINT は登録しない (requirements の確定判断。POSIX 慣習 128+2 を尊重)

### DD-6: `canceled` の契約追加

- `NotificationResult` に `.canceled` を追加。JSON は `{"result":"canceled"}` (既存のキー順規約)
- `ResultEmitter.canceledExitCode = 5`、`exitCode(for: .canceled) = 5`。予約 (1, 2)・使用済み (3, 4, 10+) と衝突しない
- `--print result` → `canceled`、他フィールドは値なし (既存の 2.4 規則にそのまま乗る)
- `--exit-code` 未指定時は既存どおり 0 (`forResult` の policy 分岐が自動的に満たす)

### 検証記録 (2026-07-31, /kiro-validate-design)

- **DD-1**: `base64("abc")` が `base64("abcd")` の接頭辞になることを実証し、上記の論拠を「`#` 終端が本質」へ訂正した。結論 (一致規則の正確さ) は不変
- **DD-5**: NSApplication.run() のランループ下で main queue の `DispatchSourceSignal` が SIGTERM を受信できることをプローブ実行で確認した (`signal(SIG_IGN)` + source → `kill(getpid(), SIGTERM)` → ハンドラ到達)

## D2. 合成 (design-synthesis)

- **一般化**: 「自分の通知の後始末」がタイムアウトとキャンセルの共通経路になった (DD-3)。それ以上の共通化はしない
- **Build vs Adopt**: シグナル処理は GCD の `DispatchSource` を採用 (自前の sigaction 管理をしない)
- **簡素化**: 当初の「区切り文字の選定」問題を、符号化 (DD-1) により「区切り文字が原理的に出現しない」問題設定に置き換えた。一致規則の例外処理が消える

## D3. リスクと軽減

| リスク                 | 影響                                                                                             | 軽減                                                                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| group 置換の TOCTOU    | 2プロセスが同時に走査すると、互いの旧通知を消し合った後に両方が配信し、一瞬2件表示される         | 現行実装にも同種の競合窓があり悪化ではない。最後に配信された側が視覚的に勝つ。設計に既知の限界として記録                      |
| 置換走査の非同期化     | `deliver` が「一覧取得 → 削除 → add」の連鎖になり、既存の同期的な `deliver` と呼び出し形が変わる | `deliver` の completionHandler 契約は既存のまま。タイマー開始時点は従来と同じ (認可完了時) で、タイムアウトの意味は変わらない |
| 遅延 exit 中の SIGTERM | ハンドラ登録により既定の即死がなくなり、遅延 exit の最大1秒は TERM で死ななくなる                | 確定済み結果が維持されるのは Req 2.4 の意図どおり。SIGKILL の挙動は従来と同じ (孤児化) で、これは仕様外                       |
| プロトコル変更の波及   | `NotificationCenterClient` のメソッド置換がモック5クラス + LaunchGuard に及ぶ                    | 機械的な追随。identifier しか使っていないため挙動は等価。既存テストが回帰を検出する                                           |
