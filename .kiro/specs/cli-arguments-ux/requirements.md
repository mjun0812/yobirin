# Requirements Document

## Project Description (Input)

yobirin CLIのUX改善。通知の反応をシェルスクリプトやhookから扱う開発者、および coding agent (Claude Code / Codex 等) の通知hookを組んでいる人が対象。

### スコープ拡張の経緯 (2026-07-30)

当初は「引数まわり」に限定し、起動経路の変更と `doctor` を別specへ分けていた。`/kiro-validate-gap` で以下2点が判明したため、**UXに関する変更を1specへ統合する方針へ変更した**。

- 短縮フラグ (Req 6) が `PsCommand` の argv 走査を壊す。`ps` を「変更しない」ことでは回避できない副作用であり、スコープを分けると `ps` が壊れた状態で1リリースを跨ぐ。
- バンドル外でオプション値がサブコマンド名と誤認されクラッシュする既存バグ (research.md F1) が存在し、短縮フラグがその影響範囲を広げる。

### 現状の問題

- README掲載のユースケース4本すべてが `jq` を必須としている。結果が確定すれば常に exit 0 のため、シェルから見て終了コードに情報がない。
- `yobirin --help` の一覧で `notify (default)` に説明がなく、使用例もない。
- 補完スクリプトの生成 (`--generate-completion-script <shell>`) は実装上動作するが、READMEに記載がなく、かつバンドル未インストール環境では起動ゲートに阻まれて動作しない。
- `--image` に不正なパスを渡すと、通知許可取得後の添付生成失敗として生のエラー表現が露出する。
- 通知未許可時の文言が `Notifications are not permitted` のみで、どのバンドルがどこで拒否されているのか分からない。
- `--timeout` は秒数のみで、`--timeout 300` が何分なのか読み手に伝わらない。
- 短縮フラグがない。
- `yobirin` を引数なしで実行すると、何も表示せず終了する (孤児通知の掃除経路に吸われる)。
- バージョン不一致の案内が、hook からの呼び出しを含め毎回 stderr に出る。
- 「通知が出ない」ときの切り分け手段がなく、インストール時の確認通知しか手がかりがない。
- バンドル外で `--title install` のようにオプション値がサブコマンド名と一致すると、通知APIに到達してクラッシュする (既存 spec の Requirement 12 違反)。

### 何を変えるか

引数体系と出力契約 (Req 1〜6)、ヘルプと導線 (Req 7〜8)、エラー文言 (Req 9〜10)、起動経路 (Req 11〜13)、既存コマンドの追随と診断 (Req 14〜15)。

### スコープ外

- 待機中プロセスを停止する手段 (`ps` からの kill)。`yobirin ps --json` と `kill` の組み合わせで実現でき、プロセス管理はこのCLIの責務ではない。
- 結果JSONのスキーマ変更 (キーの追加・改名・削除)。
- `--message` の positional 化。既定サブコマンド方式のため `yobirin ps` のような入力がサブコマンドに解決されメッセージとして渡せないこと、および `--title` の既定値がバナーのアプリ名と重複表示になることから不採用と決定した。打鍵量の課題は Req 6 で対応する。
- `--image` のファイルサイズ上限の検証。形式と存在の検証のみを行う。

### 確定済みの設計判断

- **終了コード表** (2026-07-29): `clicked` と `replied` はいずれも 0。両者の区別は `--print text` の値が空かどうかで付ける。`action` は `10 + actionIndex`、`dismissed` は 3、`timeout` は 4。
- **`--print` のフィールド欠損時** (2026-07-29): 何も出力せず、その結果に対応する終了コードで正常終了する。

### 制約

- 既存の出力JSON契約 (`.kiro/specs/yobirin-cli/design.md`) と終了コード規約 (0 / 2 / その他非0) を壊さないこと。
- `install` / `uninstall` / `list` / `ps` / 補完スクリプト出力が通知APIに触れないという既存の不変条件を維持すること。診断コマンドはこの区分の例外として扱う (Req 15)。

## Introduction

本要件は、yobirin のCLIとしての使い勝手を対象とする。中心は3つの領域である。

第一に、通知結果をシェルから扱う経路の改善。`--exit-code` は結果を終了コードに写して `case $?` での分岐を可能にし、`--print <field>` は単一フィールドの生値を出力して `$(...)` での直接取得を可能にする。いずれも opt-in であり、未指定時は現行の「結果JSON + exit 0」を完全に維持する。

第二に、起動経路の正確化。バンドル外で継続してよいコマンドかの判定を、引数文字列の走査からコマンド解決の結果に基づく判定へ改める。これにより既存のクラッシュ経路が閉じ、補完スクリプトがバンドル未インストールでも取得できるようになる。あわせて、引数なし実行時にヘルプを表示し、孤児通知の掃除には明示的な手段を用意する。

第三に、詰まったときの自己診断。`doctor` がインストール状態・バージョン整合・PATH上のリンク・通知許可を1コマンドで報告する。

本要件は既存 spec `yobirin-cli` の拡張であり、その出力JSON契約・終了コード契約を前提として引き継ぐ。

## Boundary Context

- **In scope**: `notify` の引数と出力契約、ルートコマンドおよび各サブコマンドのヘルプ文言、補完スクリプト取得、`--image` の入力検証、通知未許可時の文言、バンドル外実行時のコマンド種別判定、引数なし実行時の振る舞い、孤児通知の明示的な掃除、バージョン不一致案内の表示条件、`ps` の引数解釈と絞り込み、環境診断コマンド、README の追随更新
- **Out of scope**: 待機中プロセスの停止手段、結果JSONのスキーマ変更、`--message` の positional 化、`--image` のサイズ上限検証、インストーラ本体 (バンドル組み立て・署名・配置) の変更、アイコンプロファイルの命名規約の変更
- **Adjacent expectations**: 診断コマンドは通知許可の状態を報告するため通知APIに触れる。既存の「インストール系コマンドは通知APIに触れない」という不変条件は `install` / `uninstall` / `list` / `ps` / 補完について維持し、診断コマンドはその区分に属さない通知系コマンドとして扱う
- **Adjacent expectations**: `--exit-code` 使用時に `dismissed` / `timeout` が非0を返すため、呼び出し側が `set -e` を有効にしている場合はスクリプトが停止する。この扱いは呼び出し側の責務であり、既定挙動 (未指定時は常に 0) は変更しない

## Requirements

### Requirement 1: 結果に応じた終了コード

**Objective:** シェルスクリプトから通知の結果で分岐する開発者として、結果種別が終了コードに現れてほしい。それにより、`jq` を介さず `case $?` だけで分岐できる。

#### Acceptance Criteria

1. Where `--exit-code` が指定されている, when 結果が `clicked` または `replied` で確定した, the notify command shall 終了コード 0 で終了しなければならない
2. Where `--exit-code` が指定されている, when 結果が `action` で確定した, the notify command shall `10 + actionIndex` を終了コードとして終了しなければならない
3. Where `--exit-code` が指定されている, when 結果が `dismissed` で確定した, the notify command shall 終了コード 3 で終了しなければならない
4. Where `--exit-code` が指定されている, when 結果が `timeout` で確定した, the notify command shall 終了コード 4 で終了しなければならない
5. While `--exit-code` が指定されていない, when 結果が確定した, the notify command shall 結果種別によらず終了コード 0 で終了しなければならない
6. Where `--exit-code` が指定されている, if 通知許可が得られなかった, then the notify command shall 既存の予約コードである終了コード 2 で終了しなければならない
7. Where `--exit-code` が指定されている, if 環境エラーが発生した, then the notify command shall 既存の予約コードである終了コード 1 で終了しなければならない
8. The notify command shall `--exit-code` の指定有無によって stdout へ出力する内容を変えてはならない

### Requirement 2: 結果フィールドの直接出力

**Objective:** 通知の返信テキストや押されたボタン名を使いたい開発者として、必要な値だけを生の文字列で受け取りたい。それにより、`$(...)` で直接変数へ代入できる。

#### Acceptance Criteria

1. Where `--print <field>` が指定されている, when 結果が確定した, the notify command shall 結果JSON全体の代わりに指定フィールドの値のみを stdout へ出力しなければならない
2. The notify command shall `--print` が受け付けるフィールドを `result` / `action` / `actionIndex` / `text` の4種類に限定しなければならない
3. If `--print` に上記4種類以外の値が指定された, then the notify command shall 通知を配信せずに引数エラーとして終了しなければならない
4. Where `--print` が指定されている, when 指定フィールドが確定した結果種別に存在しない, the notify command shall stdout へ何も出力せず、その結果に対応する終了コードで終了しなければならない
5. The notify command shall `--print` で出力する値を、JSONのクォート・エスケープを施さない生の文字列として出力しなければならない
6. While `--print` が指定されていない, when 結果が確定した, the notify command shall 従来どおり結果JSON全体を stdout へ出力しなければならない
7. The notify command shall `--print` に出力形式の指定・テンプレート展開・複数フィールドの同時指定を受け付けてはならない

### Requirement 3: 終了コードと直接出力の併用

**Objective:** 返信テキストを取得しつつ結果種別でも分岐したい開発者として、2つのオプションを同時に使いたい。それにより、1回の呼び出しで値と分岐条件の両方を得られる。

#### Acceptance Criteria

1. When `--exit-code` と `--print` が同時に指定された, the notify command shall stdout へ `--print` の生値を出力し、かつ終了コードを結果種別に応じて決定しなければならない
2. The notify command shall `--exit-code` と `--print` の同時指定を検証エラーとして扱ってはならない

### Requirement 4: タイムアウトの単位付き指定

**Objective:** スクリプトを読む人として、待ち時間が何分なのか指定値から直接読み取りたい。それにより、秒数を暗算せずにスクリプトを理解できる。

#### Acceptance Criteria

1. When `--timeout` に単位を伴わない数値が指定された, the notify command shall 従来どおりその値を秒として解釈しなければならない
2. When `--timeout` に `h` / `m` / `s` のいずれかの単位を伴う値が指定された, the notify command shall 対応する秒数へ換算して解釈しなければならない
3. When `--timeout` に `1h30m` のように複数の単位を連結した値が指定された, the notify command shall それらの合計を秒数として解釈しなければならない
4. If `--timeout` の値が解釈できない, then the notify command shall 通知を配信せずに引数エラーとして終了しなければならない
5. If `--timeout` の換算後の秒数が正の値でない, then the notify command shall 通知を配信せずに引数エラーとして終了しなければならない
6. While `--timeout` が指定されていない, the notify command shall 従来どおり無期限に応答を待たなければならない

### Requirement 5: 標準入力からの本文読み取り

**Objective:** ビルドログの末尾などを通知本文に流し込みたい開発者として、標準入力から本文を渡したい。それにより、長い文字列をシェルの引数展開に載せずに済む。

#### Acceptance Criteria

1. When `--message` の値が `-` である, the notify command shall 標準入力を終端まで読み取った内容を通知本文として使用しなければならない
2. When 標準入力から読み取った内容の末尾に改行が含まれる, the notify command shall 末尾の改行を取り除いた内容を本文としなければならない
3. If `--message` の値が `-` であり、かつ標準入力が端末に接続されている, then the notify command shall 読み取りを開始せず、通知を配信せずにエラーとして終了しなければならない
4. While `--message` の値が `-` 以外である, the notify command shall 従来どおりその値をそのまま本文として使用しなければならない
5. When `--message -` と `--profile` が同時に指定された, the notify command shall 標準入力の内容を通知本文として使用しなければならない

### Requirement 6: 短縮フラグ

**Objective:** hookスクリプトを書く開発者として、頻用オプションを短く書きたい。それにより、1行に収まる呼び出しが書ける。

#### Acceptance Criteria

1. The notify command shall `--title` / `--message` / `--profile` / `--action` の短縮形として、それぞれ `-t` / `-m` / `-p` / `-a` を受け付けなければならない
2. The notify command shall 短縮形と従来のロング形式を同一の意味として扱わなければならない
3. When `-a` が複数回指定された, the notify command shall 従来の `--action` の繰り返し指定と同じ並び順でアクションを構成しなければならない
4. The notify command shall `--print` に短縮形を割り当ててはならない
5. The notify command shall 既存のロング形式のオプション名をすべて引き続き受け付けなければならない
6. When `-p` を用いてプロファイルが指定された, the notify command shall プロファイルのバンドルへ引き継いだ後に再度プロファイル解決を行ってはならない

### Requirement 7: ヘルプの自己説明性

**Objective:** 初めて yobirin を使う開発者として、ヘルプだけで何ができるか判断したい。それにより、READMEを開かずに使い始められる。

#### Acceptance Criteria

1. When ルートコマンドのヘルプが表示された, the yobirin CLI shall すべてのサブコマンドについて、そのサブコマンドが何をするかを示す1行の説明を表示しなければならない
2. When `notify` サブコマンドのヘルプが表示された, the notify command shall コマンド自体の説明と、代表的な使用例を表示しなければならない
3. The notify command shall ヘルプに示す使用例として、完了通知・アクションボタンによる承認確認・返信テキストの取得の3種類を含めなければならない
4. The yobirin CLI shall ヘルプおよび案内メッセージを英語で表示しなければならない

### Requirement 8: 補完スクリプトへの導線

**Objective:** yobirin を日常的に使う開発者として、シェル補完を有効にしたい。それにより、オプション名を記憶せずに済む。

#### Acceptance Criteria

1. When 補完サブコマンドがシェル名を伴って実行された, the yobirin CLI shall 指定されたシェル向けの補完スクリプトを stdout へ出力しなければならない
2. The yobirin CLI shall 補完対象のシェルとして `bash` / `zsh` / `fish` を受け付けなければならない
3. If 未対応のシェル名が指定された, then the yobirin CLI shall 補完スクリプトを出力せずにエラーとして終了しなければならない
4. When 補完サブコマンドがバンドル未インストールの状態で実行された, the yobirin CLI shall インストールを要求せずに補完スクリプトを出力しなければならない
5. The yobirin CLI shall 従来の補完スクリプト生成オプションを引き続き受け付けなければならない
6. When 従来の補完スクリプト生成オプションがバンドル未インストールの状態で指定された, the yobirin CLI shall インストールを要求せずに補完スクリプトを出力しなければならない
7. The yobirin documentation shall シェルごとの補完スクリプト導入手順を README に記載しなければならない
8. The 補完サブコマンド shall 通知APIに依存せずに完走しなければならない

### Requirement 9: 画像添付の事前検証

**Objective:** `--image` を使う開発者として、パスを間違えたときに何が悪いのかすぐ分かってほしい。それにより、通知許可のダイアログや内部エラー表現に煩わされずに修正できる。

#### Acceptance Criteria

1. When `--image` が指定された, the notify command shall 通知許可を要求する前に、指定パスの存在と読み取り可否を検証しなければならない
2. If `--image` に指定されたパスが存在しない、または読み取れない, then the notify command shall 通知を配信せず、対象パスを含むエラーメッセージを stderr へ表示して終了しなければならない
3. If `--image` に指定されたファイルの拡張子が添付として対応する画像形式でない, then the notify command shall 通知を配信せず、対応する形式を示すエラーメッセージを stderr へ表示して終了しなければならない
4. The notify command shall `--image` の検証失敗時に、フレームワーク由来の内部エラー表現をそのまま表示してはならない
5. While `--image` が指定されていない, the notify command shall 添付に関する検証を行ってはならない

### Requirement 10: 通知未許可時の案内

**Objective:** 通知が出ないことに気付いた利用者として、どのバンドルがどこで拒否されているのか知りたい。それにより、システム設定のどこを開けばよいか分かる。

#### Acceptance Criteria

1. If 通知許可が得られなかった, then the notify command shall 対象バンドルの名称を含むエラーメッセージを stderr へ表示しなければならない
2. If 通知許可が得られなかった, then the notify command shall システム設定で通知の許可を変更する場所への案内をエラーメッセージに含めなければならない
3. While `--profile` が指定されている, if 通知許可が得られなかった, then the notify command shall そのプロファイルに対応するバンドルの名称を表示しなければならない
4. If 通知許可が得られなかった, then the notify command shall 既存の予約コードである終了コード 2 で終了しなければならない
5. If 通知許可が得られなかった, then the notify command shall 結果JSONを出力してはならない

### Requirement 11: バンドル外実行時のコマンド種別判定

**Objective:** バンドル外の実行ファイルを直接使う利用者として、どんな引数を渡してもクラッシュしないでほしい。それにより、オプションの値がサブコマンド名と一致しても安全に使える。

#### Acceptance Criteria

1. The yobirin CLI shall バンドル外実行時のコマンド種別を、引数文字列の位置走査ではなくコマンド解決の結果に基づいて判定しなければならない
2. When オプションの値がサブコマンド名と一致する引数がバンドル外で与えられた, the yobirin CLI shall その値をサブコマンド名として解釈してはならない
3. If バンドル外で通知の配信を要求された, then the yobirin CLI shall 通知APIに到達する前にインストール済みバンドルへ実行を引き継ぐか、インストール案内を表示して終了しなければならない
4. The yobirin CLI shall バンドル外実行時に、いかなる引数の組み合わせに対しても通知APIの初期化に起因する異常終了を起こしてはならない
5. If バンドル外で与えられた引数が解釈できない, then the yobirin CLI shall バンドルへ引き継がずに引数エラーを表示して終了しなければならない
6. When バンドル外でヘルプ・バージョン・インストール系・一覧系・補完のいずれかが要求された, the yobirin CLI shall バンドルへ引き継がずにその要求を完了しなければならない

### Requirement 12: 引数なし実行時の振る舞いと明示的な掃除

**Objective:** 初めて `yobirin` と打った利用者として、何が起きるか分かる出力を得たい。それにより、コマンドが動いているのか壊れているのか判断できる。

#### Acceptance Criteria

1. When 引数なしで実行され、かつ標準入力・標準出力・標準エラーのいずれかが端末に接続されている, the yobirin CLI shall ヘルプを表示して終了しなければならない
2. When 引数なしで実行され、かついずれの標準ストリームも端末に接続されていない, the yobirin CLI shall 従来どおり配信済みの孤児通知を削除して終了しなければならない
3. The yobirin CLI shall 配信済みの孤児通知を削除する明示的なサブコマンドを提供しなければならない
4. When 掃除サブコマンドが実行された, the yobirin CLI shall 標準ストリームの接続状態によらず配信済み通知を削除しなければならない
5. When 掃除サブコマンドが実行された, the yobirin CLI shall 削除した通知の件数を表示しなければならない
6. The yobirin documentation shall 孤児通知の復旧手順として掃除サブコマンドを README に記載しなければならない

### Requirement 13: バージョン不一致案内の表示条件

**Objective:** hook から毎分 yobirin を呼ぶ利用者として、更新案内でログを埋めたくない。それにより、本当のエラーだけが stderr に残る。

#### Acceptance Criteria

1. While 標準エラーが端末に接続されている, if インストール済みバンドルのバージョンが実行中のバイナリと異なる, then the yobirin CLI shall 更新を促す案内を stderr へ表示しなければならない
2. While 標準エラーが端末に接続されていない, if インストール済みバンドルのバージョンが実行中のバイナリと異なる, then the yobirin CLI shall 案内を表示してはならない
3. The yobirin CLI shall 案内の表示有無によって処理の成否および終了コードを変えてはならない
4. The yobirin CLI shall 案内を stdout へ出力してはならない

### Requirement 14: 待機プロセス一覧の引数解釈と絞り込み

**Objective:** 待機中の通知を確認する利用者として、短縮フラグや単位付きタイムアウトで起動したプロセスも正しく一覧に出てほしい。それにより、一覧が実態と一致する。

#### Acceptance Criteria

1. When 短縮形のタイトル指定のみで起動された通知プロセスが存在する, the ps command shall そのプロセスを一覧の対象に含めなければならない
2. When 一覧対象のプロセスがタイトルを短縮形で指定している, the ps command shall そのタイトルを表示しなければならない
3. When 一覧対象のプロセスが単位付きのタイムアウトを指定している, the ps command shall その指定を秒数へ換算して扱わなければならない
4. The ps command shall タイムアウトの解釈に notify コマンドと同一の変換規則を用いなければならない
5. The ps command shall テキスト表示のタイムアウトを、経過時間と同じ人間可読の形式で表示しなければならない
6. The ps command shall 機械可読出力のタイムアウトを秒数として出力しなければならない
7. Where プロファイル名による絞り込みが指定されている, the ps command shall 該当するプロファイルのプロセスのみを一覧しなければならない
8. If 絞り込みに指定されたプロファイル名が命名規約を満たさない, then the ps command shall 一覧を出力せずにエラーとして終了しなければならない
9. The ps command shall 通知APIに依存せずに完走しなければならない

### Requirement 15: 環境診断

**Objective:** 通知が出ないことに困っている利用者として、原因の切り分けを1コマンドで済ませたい。それにより、システム設定・インストール状態・バージョンのどこに問題があるか分かる。

#### Acceptance Criteria

1. When 診断サブコマンドが実行された, the doctor command shall インストール済みバンドルの有無とバージョンを報告しなければならない
2. When 診断サブコマンドが実行された, the doctor command shall 実行中のバイナリのバージョンとインストール済みバンドルのバージョンの一致状況を報告しなければならない
3. When 診断サブコマンドが実行された, the doctor command shall PATH上のリンクの有無と、それが存在するバンドルを指しているかを報告しなければならない
4. While バンドル内で実行されている, when 診断サブコマンドが実行された, the doctor command shall 通知許可の状態を報告しなければならない
5. While バンドル外で実行されており、かつ既定バンドルが未インストールである, when 診断サブコマンドが実行された, the doctor command shall インストール案内で終了せず、通知許可を判定不能として報告を完了しなければならない
6. If 診断で1件以上の問題が検出された, then the doctor command shall 各問題に対して次に取るべき操作を提示しなければならない
7. If 診断で問題が検出されなかった, then the doctor command shall 終了コード 0 で終了しなければならない
8. If 診断で1件以上の問題が検出された, then the doctor command shall 非0の終了コードで終了しなければならない
9. Where 機械可読出力が指定されている, the doctor command shall 診断結果を機械可読な形式で stdout へ出力しなければならない
