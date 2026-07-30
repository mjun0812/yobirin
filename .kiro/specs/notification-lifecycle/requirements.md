# Requirements Document

## Project Description (Input)

yobirinの通知ライフサイクル改善: identifier分離 (バグ修正) + SIGTERMキャンセル。

詳細は `.kiro/specs/notification-lifecycle/brief.md` (discovery成果物) を参照。要点:

1. **競合バグの修正**: 通知のidentifierに `--group` の値をそのまま使っているため、同一groupのyobirinプロセスが並行すると、先行プロセスのタイムアウト掃除が後続プロセスの生きている通知を削除する。既存spec `yobirin-cli` のRequirement 5.2「自分が配信した通知を削除」の意図に実装を合わせるバグ修正。
2. **SIGTERMキャンセル**: SIGTERMを受けた待機プロセスが、自分の配信済み通知を削除してから `canceled` 相当の結果で正常終了する。hookの `pkill -f <group文字列>` 運用で「会話再開時に古い通知を消す」を実現するための機構。
3. **契約への影響**: 新しい結果種別 `canceled` は出力JSON契約 (`yobirin-cli` 所有)・`--exit-code` 対応表・`--print result` (`cli-arguments-ux` 所有) への追加になる。既存の結果5種の挙動は変更しない。終了コードは5 (1/2は予約、3/4/10+は使用済み)。
4. **requirementsで確定した判断**: SIGINTはスコープ外とする。`pkill` の既定シグナルはTERMでhook用途には十分であり、Ctrl-Cには「128+2で終了する」というPOSIX慣習の期待があるため、`canceled` で上書きすると対話利用を混乱させる。

## Introduction

本要件は、yobirin の待機プロセスが「自分が配信した通知」を正しく後始末できるようにするものである。2つの変更は同じ不変条件 — 各プロセスは自分の通知だけに責任を持つ — の表裏にあたる。

第一に、バグ修正。現在、同一 `--group` を指定した複数の yobirin プロセスが並行すると、通知を識別する内部名が group 単位で共有されているため、先に起動したプロセスのタイムアウト掃除が、後から配信された生きている通知を誤って削除する。coding agent の hook 運用では「同じセッションの2つ目の通知が黙って早死にする」症状として現れる。修正後は、削除が常に「自分が配信した1件」に限定される。

第二に、キャンセル機構。SIGTERM を受けた待機プロセスは、自分の配信済み通知を通知センターから削除したうえで、`canceled` という結果で正常終了する。これにより hook は、会話再開時に `pkill -f <group文字列>` の1行で古い通知を能動的に消せる。`canceled` は6番目の結果種別として、結果JSON・`--exit-code`・`--print` の各契約に追加される。

既存の結果5種 (clicked / action / replied / dismissed / timeout) の JSON 出力・終了コード・削除挙動は一切変更しない。

## Boundary Context

- **In scope**: 並行する同一 group プロセス間での通知削除の正確化、group 置換挙動の維持、SIGTERM 受信時のキャンセル (通知削除・`canceled` の結果確定・終了)、`canceled` の出力契約 (結果JSON・`--exit-code`・`--print`)、README (en/ja) への追記
- **Out of scope**: SIGINT ほか他シグナルへの対応 (上記の確定判断)、`dismiss` サブコマンドの新設、`sweep` / `ps` / `doctor` の挙動変更、dotfiles 側の hook スクリプト変更 (別リポジトリ)、待機プロセスの一覧からの停止 UX
- **Adjacent expectations**: 既存 spec `yobirin-cli` の出力JSON契約と `cli-arguments-ux` の `--exit-code` / `--print` 契約に `canceled` を**追加**する形で参照する。両 spec の文書は書き換えない (契約の差分は本 spec が所有する)
- **Adjacent expectations**: キャンセルの発動はプロセスへの SIGTERM 送達に依存する。どのプロセスへ送るかの特定 (`pkill -f` によるgroup文字列の argv 一致など) は呼び出し側の責務であり、本 spec は受信後の振る舞いのみを所有する

## Requirements

### Requirement 1: 自分が配信した通知に限定した削除

**Objective:** 同一 group の通知を並行して使う開発者として、あるプロセスの後始末が別のプロセスの生きている通知を消さないでほしい。それにより、通知が黙って消える症状がなくなる。

#### Acceptance Criteria

1. While 同一の `--group` を指定した複数の通知プロセスが並行している, when いずれかのプロセスがタイムアウトで確定した, the notify command shall 自分が配信した通知のみを通知センターから削除しなければならない
2. While 同一の `--group` を指定した複数の通知プロセスが並行している, when いずれかのプロセスが通知を削除した, the notify command shall 他のプロセスが配信した表示中の通知を削除してはならない
3. When `--group` を指定して通知を配信する, the notify command shall 配信の直前に、同一 group の既存の配信済み通知をすべて削除しなければならない (置換挙動の維持)
4. If ある group の値が別の group の値の先頭部分と一致している (例: `a` と `ab`), then the notify command shall 別 group の通知を誤って削除してはならない
5. While `--group` が指定されていない, the notify command shall 既存の配信済み通知をいかなる契機でも削除の対象へ含めてはならない (タイムアウト時の自分の通知を除く)
6. The notify command shall 本修正によって結果JSONの内容・終了コード・応答検知の挙動を変えてはならない

### Requirement 2: SIGTERMによるキャンセル

**Objective:** coding agent の hook を組む開発者として、応答待ちのプロセスへ SIGTERM を送るだけで通知ごと片付けたい。それにより、会話再開時に古い通知を1行で消せる。

#### Acceptance Criteria

1. While 通知を配信して応答を待っている, when SIGTERM を受信した, the notify command shall 自分が配信した通知を通知センターから削除しなければならない
2. When SIGTERM によるキャンセルが確定した, the notify command shall 結果種別 `canceled` として結果を確定し、既存の結果出力と同じ経路で終了しなければならない
3. The notify command shall キャンセルによる通知の削除をプロセスの終了より前に完了しなければならない
4. While 結果が既に確定している (応答・タイムアウト・先行するキャンセル), if SIGTERM を受信した, then the notify command shall 確定済みの結果を変更してはならない
5. If 通知の配信前 (許可の要求中など) に SIGTERM を受信した, then the notify command shall 以降通知を配信せず、`canceled` として終了しなければならない
6. While SIGTERM を受信していない, the notify command shall 従来と同一に動作しなければならない
7. The notify command shall SIGINT の既定動作を変更してはならない (スコープ外の確定判断)

### Requirement 3: canceled の出力契約

**Objective:** シェルスクリプトから yobirin を扱う開発者として、キャンセルも他の結果と同じ流儀で受け取りたい。それにより、既存の分岐に1ケース足すだけで対応できる。

#### Acceptance Criteria

1. When キャンセルが確定した, the notify command shall `{"result":"canceled"}` の形式で結果JSONを stdout へ出力しなければならない
2. Where `--exit-code` が指定されている, when キャンセルが確定した, the notify command shall 終了コード 5 で終了しなければならない
3. While `--exit-code` が指定されていない, when キャンセルが確定した, the notify command shall 終了コード 0 で終了しなければならない
4. Where `--print result` が指定されている, when キャンセルが確定した, the notify command shall `canceled` を生の文字列として stdout へ出力しなければならない
5. Where `--print` に `action` / `actionIndex` / `text` が指定されている, when キャンセルが確定した, the notify command shall stdout へ何も出力せず、その結果に対応する終了コードで終了しなければならない
6. The notify command shall 既存の結果5種 (clicked / action / replied / dismissed / timeout) のJSON出力・終了コードを変更してはならない
7. The notify command shall `canceled` の終了コードを既存の予約コード (1: 環境エラー、2: 未許可) および使用済みコード (3: dismissed、4: timeout、10以上: action) と衝突させてはならない

### Requirement 4: ドキュメントの追随

**Objective:** yobirin の利用者として、キャンセルの使い方と結果の読み方を README で知りたい。それにより、hook への組み込みを自力で設計できる。

#### Acceptance Criteria

1. The yobirin documentation shall 結果種別の一覧に `canceled` を追記しなければならない (README の en / ja 両方)
2. The yobirin documentation shall `--exit-code` の対応表に `canceled` → 5 を追記しなければならない
3. The yobirin documentation shall SIGTERM による通知キャンセルの用途と使い方 (待機プロセスへのシグナル送達で通知ごと片付く) を記載しなければならない
