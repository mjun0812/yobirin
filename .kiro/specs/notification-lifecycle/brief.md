# Brief: notification-lifecycle

## Problem

coding agent の hook から yobirin を使う開発者 (作者自身の dotfiles 構成を含む) が、通知の後始末で2つの問題を抱えている。

1. **競合バグ**: 同一 `--group` の yobirin プロセスが並行すると、先行プロセスのタイムアウト掃除が後続プロセスの生きている通知を削除する。通知の identifier に `--group` の値をそのまま使っているため、プロセスが「自分の通知」と「同名の他人の通知」を区別できない。dotfiles の実運用では「同じセッションで stop 通知が5分以内に2回出ると、2つ目の通知が黙って早死にする」症状として現れる。
2. **能動的なキャンセル手段の欠如**: hook で通知を出した後、ユーザーが通知をクリックせず会話を再開した場合に、古い通知を消す手段がない。待機プロセスを `kill` しても yobirin はシグナルを処理しないため、通知が孤児として通知センターに残り、むしろ悪化する。

## Current State

- `NotificationSession.deliver` は `identifier = group ?? UUID()` とし、group 指定時は配信前に `removeDeliveredNotifications([identifier])` で置換する
- タイムアウト確定時の削除 (`commit(.timeout)`) も同じ identifier を対象にするため、同一 group の後続プロセスの通知を誤って消す。既存 spec `yobirin-cli` の Requirement 5.2「自分が配信した通知を削除」の意図と実装が乖離している (1プロセスの世界では同値だった)
- SIGTERM / SIGINT にハンドラは無い。kill されたプロセスの通知は孤児になり、`sweep` (全件削除・自バンドル限定) か次回の group 置換まで残る
- dotfiles 側の回避運用 (`pkill -f` でプロセスを先に殺してから新しい通知を出す) は「直後に新しい通知が来る」場合しか成立しない

## Desired Outcome

- 同一 group のプロセスが何個並行しても、各プロセスは自分が配信した通知だけを削除する (競合の根絶)
- SIGTERM を受けた待機プロセスは、自分の配信済み通知を削除してから `canceled` 相当の結果で正常に終了する
- hook 側は `pkill -f <group文字列>` の1行で「会話再開時に古い通知を消す」が実現できる (group が argv に載っているため PID 管理は不要)
- 既定の挙動 (シグナルを受けないプロセスの動作、既存の JSON 出力・終了コード) は一切変わらない

## Approach

**identifier 分離 + SIGTERM キャンセルを1つの spec で実装する** (討議した3案のうち案1)。

- identifier を「group + 区切り + ユニーク接尾辞」へ分離する。group 置換は `getDeliveredNotifications` (sweep が使用中の既存API) で配信済み一覧を取得し、group に対応する前方一致で走査して削除する。タイムアウト・キャンセル時の自己削除はユニークな identifier を対象にする
- SIGTERM は `DispatchSource.makeSignalSource` で受け、通知削除 → 結果確定 (`canceled`) → 遅延 exit の既存経路に乗せる。`NotificationSession` の一度きり確定機構 (先着1件) をそのまま使い、応答とキャンセルの競合も既存の排他で解決する

却下した代替案: 案2 (バグ修正のみ先行) はキャンセル要望が未解決のまま残り、後で同じファイルを触る。案3 (`dismiss` サブコマンド) は通知を消しても待機プロセスが残るため、結局プロセスの扱いが必要になり案1に収斂する。

## Scope

- **In**: identifier の内部構造の分離、group 置換の走査ロジック、タイムアウト/キャンセル時の自己削除、SIGTERM ハンドリング、結果種別 `canceled` の追加 (JSON 出力・`--exit-code` 対応表・`--print result`)、README への追記
- **Out**: dotfiles 側の hook スクリプト変更 (別リポジトリ)、`dismiss` サブコマンドの新設、SIGINT 以外への拡張判断 (SIGINT を含めるかは requirements で決める)、`sweep` / `ps` の挙動変更

## Boundary Candidates

- identifier の構成規則 (group ⇔ identifier の変換・逆引き) — `NotificationSession` 内の単一ソースにする候補
- シグナル受信からキャンセル確定までの経路 — 既存の timeout 経路 (`Scheduler` → `handleTimeout`) と対になる `handleCancel` 相当
- `canceled` の出力契約 — `ResultEmitter` / `PrintField` / 終了コード表 (値は 5 が候補。1/2 は予約、3/4 は使用済み)

## Out of Boundary

- 待機プロセスの一覧・停止のUX (`ps` からの kill 等) — プロセス管理は CLI の責務外という既決事項を維持
- 通知センターの他バンドル通知への操作 (UN API の制約上不可能)

## Upstream / Downstream

- **Upstream**: `yobirin-cli` spec (出力JSON契約、Requirement 5.2 の意図、NotificationSession の排他確定機構)、`cli-arguments-ux` spec (`--exit-code` / `--print` の契約、TerminalDetection 等の共有部品)
- **Downstream**: dotfiles の hook スクリプト (turn_start での `pkill -f` 運用が本機能を前提にする)。将来の `doctor` 拡張が identifier 規則を参照する可能性

## Existing Spec Touchpoints

- **Extends**: なし (既存 spec の文書は書き換えない。契約の差分は本 spec が所有する)
- **Adjacent**: `yobirin-cli` — 出力JSON契約に `{"result":"canceled"}` を追加する形で参照。Requirement 5.2 の実装乖離を本 spec のバグ修正として扱う / `cli-arguments-ux` — `--exit-code` の対応表と `PrintField` に `canceled` を追加する形で参照

## Constraints

- 既存の結果5種の JSON 出力・終了コードは変更しない (後方互換)。`canceled` は追加のみ
- 予約済み終了コード (1: 環境エラー、2: 未許可) および使用済み (3: dismissed、4: timeout、10+: action) と衝突させない
- `--group` の値は任意の文字列であるため、identifier の区切り文字が group 文字列と衝突しても誤削除が起きない一致規則にする (設計フェーズの決定事項)
- シグナル受信後の通知削除は exit より前に完了しなければならない (`LaunchGuard` のセマフォ待ち方式の前例に従う)
- `NotificationSession` の「一度きり確定」の不変条件を壊さない (キャンセルと応答の競合は既存の排他で先着が勝つ)
