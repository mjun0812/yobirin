# Gap Analysis: cli-arguments-ux

_実施日: 2026-07-30 / 対象: `.kiro/specs/cli-arguments-ux/requirements.md` (Requirement 1〜10)_

## 調査サマリ

- 要件10件のうち8件は既存の注入パターン (`perform(...)` 静的関数 + 純粋関数) にそのまま乗る。新規の構造は不要。
- ただし **既存コードの3箇所が「引数を文字列として素朴に走査する」実装になっており**、短縮フラグ (Req 6) と単位付きタイムアウト (Req 4) がそれらを壊す。うち1件 (`ProfileDispatch.buildExecArguments`) は exec 無限ループを引き起こす。
- 調査中に **既存バグを1件実測で確認した** (F1)。本specの要件ではないが、Req 6 が影響範囲を広げるため設計時に扱いを決める必要がある。
- Req 5 (`--message -`) は多段exec構成と正面から衝突する。stdin を読む位置を誤ると、`--profile` 併用時に本文が空になる。
- 工数は全体で **M (3〜7日)**、リスクは **Medium**。リスクの大半は新機能そのものではなく、既存の引数走査コードとの相互作用に由来する。

---

## 1. 現状のアセット把握

### 1.1 引数定義とパース

| 資産                  | 場所                                               | 本specとの関係                                                                                                                                                                                    |
| --------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NotifyCommand`       | `Sources/yobirin/NotifyCommand.swift` (104行)      | Req 1〜6, 9 の主戦場。`@Option` 11個 + `validate()` + `makeNotificationRequest()`                                                                                                                 |
| `YobirinCommand`      | `Sources/yobirin/Yobirin.swift:163`                | Req 7 (abstract)、Req 8 (`completion` サブコマンド追加先)                                                                                                                                         |
| `parseTimeout`        | `NotifyCommand.swift:53`                           | Req 4 の拡張点。`transform:` に渡す純粋関数で、テスト容易性は既に確保済み                                                                                                                         |
| swift-argument-parser | 1.8.2 (`Package.resolved`。宣言は `from: "1.3.0"`) | `CompletionShell` は `zsh` / `bash` / `fish` の3種のみ。`ParsableArguments.completionScript(for:)` が public API として存在 (`Sources/ArgumentParser/Parsable Types/ParsableArguments.swift:208`) |

Req 8.2 が要求する3シェルは、依存ライブラリの対応範囲と正確に一致する。`CompletionShell` は `RawRepresentable` + `CaseIterable` だが `ExpressibleByArgument` には適合していないため、サブコマンドの引数として受けるには薄い適合か文字列受けの変換が要る。

### 1.2 出力と終了コードの経路

```text
NotificationSession.commit(result)
  → AppDelegate.init の onResult クロージャ        ← ここで ResultEmitter.forResult を呼ぶ
      → ResultEmitter.forResult(ResultOutput)      ← 出力先・本文・終了コードを決める純粋関数
          → EmittedOutput { destination, text, exitCode }
              → ExitCoordinator.finish(writer:scheduler:exit:)  ← 書き込み + 1秒遅延 exit
```

- `ResultEmitter` は「終了コードの単一ソース」として設計されており (`structure.md`「終了コードは `ResultEmitter` の定数を参照し、magic number を書かない」)、Req 1 の追加コードもここへ集約するのが既存方針に合致する。
- `ResultOutput.jsonString()` (`Output.swift:21`) がキー順を固定した JSON を組み立てている。Req 2 (`--print`) は「同じ結果値から別表現を作る」ことになるため、`ResultOutput` に表現を1つ足す形が素直。
- `ExitCoordinator.finish` は既に `EmittedOutput.exitCode` をそのまま使って exit する。**Req 1 のために `ExitCoordinator` を変更する必要はない**。
- `ResultEmitter.forResult` の呼び出しは実装1箇所 (`AppDelegate.swift:29`) + テスト2箇所 (`AppFlowTests.swift:175`, `IntegrationFlowTests.swift:143`) + 単体テスト1箇所 (`OutputTests.swift:115`)。引数を増やす場合はデフォルト値を付ければ既存テストは無改修で通る。

**ギャップ**: `AppDelegate.init` の `onResult` クロージャは CLI オプションを知らない。`--exit-code` / `--print` の指定を `NotifyCommand` から `AppDelegate` を経て `ResultEmitter` まで運ぶ経路が現状存在しない。`NotificationRequest` は通知の内容を表す型であり、出力方針を混ぜるのは責務が異なる。

### 1.3 多段exec構成 (最重要の制約)

`yobirin --profile claude ...` を PATH 上の symlink から実行した場合、プロセスは最大4回入れ替わる。

```text
[1] symlink 経由起動
     BundleEnvironment.reExecThroughSymlinkIfNeeded()  → 実体パスへ execv
[2] バンドル外の素の Mach-O
     LaunchGate.decide() → .execInstalledBundle
     BundleHandoff.execDefaultBundle()                 → 既定バンドルへ execv
     ※ ArgumentParser はここではまだ動かない
[3] Yobirin.app 内
     ArgumentParser がパース → NotifyCommand.validate() → run()
     run() が --profile を見て ProfileDispatch.dispatch() → 対象バンドルへ execv
[4] Yobirin-Claude.app 内
     ArgumentParser がパース → validate() → run() → 実際に通知を配信
```

重要な性質:

- `validate()` は **[3] と [4] の両方で実行される**。副作用のない検証なら二重実行は無害。
- `makeNotificationRequest()` は [4] でしか実行されない ([3] は `dispatch` して return するため)。
- `ProfileDispatch.buildExecArguments` (`ProfileDispatch.swift:140`) が `--profile` を除去することで [4] の再ディスパッチを防いでいる。ソースのコメントが「ディスパッチ先には `--profile` が渡らないため、再ディスパッチは構造的に起きない」と明記しているとおり、**この除去が無限ループ防止の唯一の仕組み**。

### 1.4 引数を文字列として走査している箇所

型を通さず argv を素朴に走査しているコードが3箇所ある。これが本specの主要な衝突源になる。

| 箇所                                                                               | 走査内容                                                                 | 目的                                   |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------- |
| `LaunchGate.isRoutableOutsideBundle` (`Yobirin.swift:85`)                          | `rest.first { !$0.hasPrefix("-") }` をサブコマンド名と照合               | バンドル外で継続してよいコマンドか判定 |
| `ProfileDispatch.buildExecArguments` (`ProfileDispatch.swift:140`)                 | `--profile` / `--profile=` を除去                                        | 再ディスパッチ防止                     |
| `PsCommand.argvContainsTitleFlag` / `extractOption` (`PsCommand.swift:165`, `171`) | `--title` の有無で通知プロセスを判定、`--title` / `--timeout` の値を抽出 | `ps` の対象判定と表示                  |

### 1.5 テスト配置

1ソース1テストファイルの規約。本specで触れる範囲の既存テストは以下。

- `NotifyCommandTests.swift` — 引数パース・`validate()`・`makeNotificationRequest()`
- `OutputTests.swift` — `ResultOutput.jsonString()` と `ResultEmitter`
- `AppFlowTests.swift` / `IntegrationFlowTests.swift` — 認可〜出力の結線
- `LaunchGateTests.swift` — 起動ゲートの純粋関数
- `ProfileDispatchTests.swift` — `buildExecArguments` を含む
- `PsCommandTests.swift` — argv 走査ロジック
- `ProcessLaunchIntegrationTests.swift` — 実バイナリのプロセス起動による結合テスト

Req 1〜6, 9 はいずれも純粋関数または `perform(...)` 相当に落とせるため、既存のテスト方針 (fake 注入 + テンポラリ領域) で自動テスト可能。Req 10 のメッセージ内容も `AppFlow` のテストで検証できる。

---

## 2. 要件 → 資産マップ

| 要件                | 主な既存資産                                         | 変更の性質                                                | ギャップ分類                |
| ------------------- | ---------------------------------------------------- | --------------------------------------------------------- | --------------------------- |
| 1. 終了コード       | `ResultEmitter`, `AppDelegate.init`, `NotifyCommand` | 出力方針をコマンドから `ResultEmitter` まで運ぶ経路の新設 | **Missing** (経路)          |
| 2. `--print`        | `ResultOutput`, `ResultEmitter`                      | `ResultOutput` に単一フィールド抽出を追加                 | **Missing** (表現)          |
| 3. 併用             | 同上                                                 | 1・2 の合成。追加資産なし                                 | なし                        |
| 4. 単位付き timeout | `NotifyCommand.parseTimeout`                         | 純粋関数の拡張                                            | なし (ただし F3)            |
| 5. `--message -`    | `NotifyCommand.makeNotificationRequest`              | stdin 読み取りの追加                                      | **Constraint** (F4)         |
| 6. 短縮フラグ       | `@Option(name:)`                                     | 宣言の変更のみ                                            | **Constraint** (F2, F3, F1) |
| 7. ヘルプ           | `CommandConfiguration`                               | `abstract` / `discussion` の追加                          | なし                        |
| 8. completion       | `YobirinCommand.subcommands`, `LaunchGate`           | サブコマンド新設 + 許可リスト追加                         | **Missing** (F5)            |
| 9. `--image` 検証   | `NotifyCommand.validate()`                           | 検証の追加                                                | **Unknown** (F7)            |
| 10. 未許可時の案内  | `AppFlow.handleAuthorization`                        | バンドル名の取得経路が必要                                | **Missing** (F8)            |

---

## 3. 検出した衝突・リスク

### F1: 既存バグ — オプション値がサブコマンド名と誤認され、バンドル外でクラッシュする

**分類**: 既存の不具合 (本specの要件外)。ただし Req 6 が影響範囲を広げる。

`LaunchGate.isRoutableOutsideBundle` は `rest.first { !$0.hasPrefix("-") }` で「最初の非フラグ引数」をサブコマンド名として照合する。この走査はオプションの**値**とサブコマンド名を区別できない。

実測 (2026-07-30、バンドル外の `.build/debug/yobirin`):

```console
$ ./.build/debug/yobirin --title install --message x --timeout 1
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'bundleProxyForCurrentProcess is nil: mainBundle.bundleURL
    file:///Users/mjun/workspace/yobirin/.build/arm64-apple-macosx/debug/'
```

対照として `--title deploy` は正常に `{"result":"timeout"}` を返す。

`--title` / `--message` / `--subtitle` などの値が `install` / `uninstall` / `list` / `ps` のいずれかに一致すると、`.runCLI` と誤判定され、バンドル外で `NSApplication` + `UserNotifications` に到達してクラッシュする。既存 spec の Requirement 12 (バンドル外実行時の安全性、「クラッシュしない」) に反する。

Req 6 で `-t install` が書けるようになると同じ経路に乗るが、**バグ自体は短縮フラグの導入前から存在する**。

**設計時の判断が必要**: (a) 本specで併せて直す、(b) 起動経路の別specへ送る、(c) 別issueとして切り出す。Req 6 を入れる以上、少なくとも「悪化させない」ことの確認は本specの責任範囲に入る。

### F2: `-p` 追加時の exec 無限ループ

**分類**: Req 6 が導入する致命的な回帰。

`ProfileDispatch.buildExecArguments` は `--profile` と `--profile=` しか除去しない。`-p` を追加した状態で `yobirin -p claude -t X -m Y` を実行すると、[4] のプロセスにも `-p claude` が残り、`NotifyCommand.run()` が再び `ProfileDispatch.dispatch` を呼ぶ。exec が成功し続けるため、プロセスは無限に自身を置き換える。

除去対象に短縮形を加える必要がある。swift-argument-parser が短縮オプションの値をどの表記で受けるか (`-p claude` / `-p=claude` / `-pclaude`) を確認し、除去ロジックを表記ごとに揃えること。`buildExecArguments` は純粋関数なのでテストは容易 (`ProfileDispatchTests.swift`)。

### F3: `ps` の表示・対象判定の回帰

**分類**: Req 4 と Req 6 が既存機能に与える副作用。

`PsCommand` は他プロセスの argv を文字列として読む。

1. **対象判定** — `argvContainsTitleFlag` は `--title` / `--title=` のみを見る。`-t` だけで起動された通知プロセスは `yobirin ps` の一覧から**完全に消える** (Req 6 起因)。
2. **TITLE 列** — `extractOption("--title", ...)` が短縮形を拾えず `-` 表示になる (Req 6 起因)。
3. **TIMEOUT 列** — `timeoutSeconds` は `Int($0)` で変換するため、`--timeout 5m` は `nil` になり `-` 表示になる (Req 4 起因)。

`ps` 自体は本specのスコープ外 (Boundary Context の Out of scope) だが、これは「`ps` を変更しない」ことでは守れない類の副作用である。既存機能を壊さないための追随変更として本specに含めるか、別specの前提条件として明示的に引き渡すかを決める必要がある。

### F4: `--message -` を読む位置

**分類**: Req 5 の実装制約。

1.3 の多段exec構成より、**stdin の読み取りは `validate()` で行ってはならない**。`validate()` は [3] のホップでも実行されるため、そこで stdin を EOF まで読むと、`ProfileDispatch.dispatch` で exec した [4] のプロセスには空の stdin しか残らず、`--profile` 併用時に本文が消える。

読み取りは `makeNotificationRequest()` 側 ([4] でしか実行されない) に置く。`validate()` で行ってよいのは Req 5.3 の「stdin が端末に接続されているか」の判定 (`isatty`) までで、これは読み取りを伴わないため安全。

同じ理由で、Req 9 の `--image` 検証は `validate()` に置いて問題ない (ファイル I/O は冪等で、二重実行しても副作用がない)。

### F5: `completion` はバンドル外の許可リストに載っていない

**分類**: Req 8.4 が要求する変更点。

`LaunchGate.isRoutableOutsideBundle` の許可リストは `["install", "uninstall", "list", "ps"]`。ここに `completion` を追加しないと、バンドル未インストールの環境では補完スクリプトを出力せずインストール案内で終了する。

既存の `--generate-completion-script` にも同じ問題がある。`--` で始まるためリストの照合対象にならず、続く `zsh` が最初の非フラグ引数として拾われるが、これも許可リストに無いため `.guideInstall` に落ちる。現在の開発機では既定バンドルがインストール済みのため `.execInstalledBundle` 経由で動作しているだけで、**未インストール環境では現状すでに動かない**。

Req 8.5 (従来オプションの継続受理) を満たすには、サブコマンド追加だけでなくこの許可リストの扱いも設計に含める必要がある。

なお `completion` サブコマンドは通知 API に触れてはならない (`structure.md` の import 規律)。`completionScript(for:)` は `ArgumentParser` のみに依存するため、この制約は自然に満たせる。

### F6: 出力方針を運ぶ経路が存在しない

**分類**: Req 1・2 の構造上のギャップ。1.2 に詳述。

`NotifyCommand` → `AppDelegate` → `NotificationSession.onResult` → `ResultEmitter` の経路に、`--exit-code` / `--print` の指定を運ぶ手段がない。`AppFlow` 経由の出力 (未許可・配信失敗) は既存の終了コードを使うため影響を受けないが、`AppDelegate.init` の `onResult` クロージャは新しい方針を参照する必要がある。

### F7: 添付として対応する形式の判定手段 — **Research Needed**

**分類**: Req 9.3 の未確定事項。

`UNNotificationAttachment` が受け付ける形式 (画像 / 音声 / 動画) と、形式ごとのサイズ上限は Apple のドキュメントに記載があるが、本リポジトリでは未検証。以下を設計フェーズで確定させる必要がある。

- 対応形式の判定を拡張子で行うか、UTType で行うか
- サイズ上限を検証対象に含めるか (Req 9 は形式と存在のみを要求しており、上限超過は現状 F9 の生エラー経路に残る)
- `--image` に画像以外 (音声・動画) を許すのか。オプション名と既存ヘルプ (`Path of an image to attach`) は画像を前提にしている

要件を最小に保つなら「存在・読み取り可否 + 画像拡張子」に限定するのが `CLAUDE.md` の「起こり得ないケースのための過剰なエラー処理をしない」に沿う。

### F8: 未許可メッセージに載せるバンドル名の取得

**分類**: Req 10 の小さなギャップ。

`AppFlow.handleAuthorization` はバンドルの identity を知らない。プロセスは対象バンドル内で動いているため、`Bundle.main` から直接取得するか、`ProfileNaming` から導出するかの選択になる。既存方針 (`structure.md`:「インストール規約由来の名前は `ProfileNaming` が単一ソース。他の場所で文字列組み立てをしない」) に従うなら後者だが、`ProfileNaming` はプロファイル名からの順方向導出を前提としており、`AppFlow` はプロファイル名を保持していない。`Bundle.main.bundleURL.lastPathComponent` からの逆引き (`ProfileNaming.recognize`) が既存資産で最も近い。

---

## 4. 実装アプローチの選択肢

### Option A: 既存コンポーネントの拡張のみ

`NotifyCommand` に `@Option` を追加し、`ResultEmitter` / `ResultOutput` にメソッドを追加、`AppDelegate.init` の引数を増やす。新規ファイルを作らない。

- ✅ ファイル数が増えない。`NotifyCommand` は 104 行と小さく、オプション2つの追加には十分な余裕がある
- ✅ `ResultEmitter` が終了コードの単一ソースであり続ける (`structure.md` 準拠)
- ❌ 出力方針を `AppDelegate.init` の引数として渡すと、引数リストが `request` / `client` / `onOutput` / `exitCodeEnabled` / `printField` と長くなる
- ❌ Req 4・5 のパース処理 (単位換算・stdin 読み取り) を `NotifyCommand` に直接書くと、100 行台のファイルが 200 行近くまで膨らむ

### Option B: 出力方針を表す小さな型を新設する

`OutputOptions` (仮) を新設し、`--exit-code` / `--print` の指定をまとめて保持する。`NotifyCommand` が構築し、`AppDelegate` を経由して `ResultEmitter.forResult(_:options:)` へ渡す。

- ✅ `AppDelegate.init` の引数増加が1つで済む
- ✅ 「出力方針」という単位でテストできる。`ResultEmitter.forResult` にデフォルト引数を与えれば既存テスト3箇所は無改修
- ✅ `NotificationRequest` (通知の内容) と出力方針が混ざらない
- ❌ 型が1つ増える。ただし `Output.swift` に同居させれば新規ファイルは不要
- ❌ `--print` のフィールド種別も列挙型として起こすことになり、小さな型が2つになる

### Option C: 段階分割 (ハイブリッド)

出力契約に触れる Req 1・2・3 と、それ以外 (Req 4〜10) を実装順で分ける。前者を Option B の形で、後者を Option A の形で入れる。

- ✅ Req 4〜10 は既存の振る舞いを壊さない独立変更で、先に入れれば手戻りが小さい
- ✅ F1〜F3 (既存コードとの衝突) は Req 4・6 に集中しており、先に潰しておくと Req 1・2 の実装が既存コードの都合から切り離される
- ✅ 手動検証 (GUI依存) が必要なのは Req 1・2・9・10 のみ。分割すると手動検証の対象が明確になる
- ❌ 実装タスクの依存順を設計時に決める必要がある

---

## 5. 工数とリスク

| 要件群                 | 工数           | リスク     | 根拠                                                                                                                    |
| ---------------------- | -------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------- |
| Req 1・2・3 (出力契約) | M              | Medium     | 純粋関数への追加自体は小さいが、`AppDelegate` までの配線変更が既存の結合テスト2件に触れる。GUI 依存のため最終確認は手動 |
| Req 4 (timeout 単位)   | S              | Low        | 純粋関数 1つの拡張。ただし F3 の `ps` 追随を伴う                                                                        |
| Req 5 (stdin)          | S              | Medium     | 実装量は小さいが F4 を外すと `--profile` 併用時に無言で壊れる。多段exec を跨ぐ結合テストが要る                          |
| Req 6 (短縮フラグ)     | S              | **High**   | 宣言変更は 1 行だが、F2 (exec 無限ループ) と F3 (`ps` の対象漏れ) を伴う。F1 の影響範囲にも触れる                       |
| Req 7 (ヘルプ)         | S              | Low        | 文言のみ。既存の振る舞いに影響しない                                                                                    |
| Req 8 (completion)     | S              | Low        | 依存ライブラリの public API で完結。F5 の許可リスト追加を忘れなければよい                                               |
| Req 9 (`--image` 検証) | S              | Medium     | F7 が未確定。対応形式の線引き次第で実装量が変わる                                                                       |
| Req 10 (未許可案内)    | S              | Low        | F8 の取得経路を決めれば文言のみ                                                                                         |
| **全体**               | **M (3〜7日)** | **Medium** | 個々は小さいが、既存の argv 走査コード3箇所との相互作用が全体リスクを押し上げる                                         |

リスクの所在が新機能ではなく既存コードとの結合にあるため、**設計フェーズで F1〜F5 の扱いを先に確定させることが工数見積りの精度に直結する**。

---

## 6. 設計フェーズへの申し送り

### 推奨アプローチ

**Option C (段階分割) + 出力方針は Option B の型を新設**。

理由は3つ。(1) F1〜F3 が Req 4・6 に集中しており、これらを先に片付けると Req 1・2 の設計が既存コードの都合から独立する。(2) `ResultEmitter` を終了コードの単一ソースとして保つ既存方針を守るには、方針を値として渡す形が最も素直。(3) 手動検証が必要な範囲 (Req 1・2・9・10) を後段にまとめられる。

### 設計で決めるべきこと

1. **F1 の扱い** — 本specで直すか、別specへ送るか、別issueにするか。Req 6 を入れる以上、判断を保留にはできない
2. **F3 の追随範囲** — `ps` の argv 走査を短縮形・単位付き timeout に対応させるか。対応する場合、`ps` の変更が本specのスコープに入ることを Boundary Context に反映する
3. **`--print` のフィールド種別の型** — 列挙型として起こすか、文字列で受けて検証するか。Req 2.2 の「4種類に限定」と Req 2.3 のエラー処理を満たす最小の形
4. **`--exit-code` と `ExitCoordinator` の関係** — 現状 `EmittedOutput.exitCode` をそのまま使えるため変更不要と見ているが、設計で追認すること
5. **F7 の線引き** — `--image` の対応形式判定を拡張子に限るか、UTType を使うか。サイズ上限を検証に含めるか
6. **F8 のバンドル名取得** — `Bundle.main` からの直接取得か、`ProfileNaming.recognize` による逆引きか
7. **`completion` サブコマンドと `--generate-completion-script` の共存** — Req 8.5 を満たす形。許可リストへの追加方法を含む

### Research Needed

- **R-1**: `UNNotificationAttachment` の対応形式とサイズ上限の一次情報 (Apple Developer Documentation)。F7 の線引きの根拠として必要
- **R-2**: swift-argument-parser 1.8.2 における短縮オプションの値表記 (`-p value` / `-p=value` / `-pvalue` のどれを受理するか)。F2 の除去ロジックの網羅性に直結する
- **R-3**: `CompletionShell` を `@Argument` として受ける方法。`ExpressibleByArgument` 非適合のため、適合を足すか文字列経由にするかの確認

---

# Design Discovery: cli-arguments-ux (スコープ拡張後)

_実施日: 2026-07-30 / ディスカバリ種別: Light (既存システムの拡張) / 契機: F1・F3 を本specで直し、UX変更を1specへ統合する方針決定_

## D1. 積み残し調査項目の結果

### R-1: `UNNotificationAttachment` の対応形式 — 解決

Apple Developer Documentation (`UNNotificationAttachment`) より、画像として対応する形式は **JPEG / GIF / PNG**、上限 10 MB。音声・動画も添付可能だが、`--image` というオプション名と既存ヘルプ (`Path of an image to attach`) が画像を前提としているため、**本specでは画像3形式に限定して検証する**。

サイズ上限の検証は要件のスコープ外とした (`requirements.md` スコープ外)。上限超過は従来どおり添付生成の失敗として環境エラー経路に落ちる。Req 9.4 が要求する「内部エラー表現をそのまま表示しない」は、この残存経路にも適用する。

出典: <https://developer.apple.com/documentation/usernotifications/unnotificationattachment>

### R-2: 短縮オプションの値表記 — 実測で解決

swift-argument-parser 1.8.2 に対する実測 (スクラッチのプローブ実行、2026-07-30):

| 表記               | 結果                                   |
| ------------------ | -------------------------------------- |
| `-p claude`        | 受理                                   |
| `-p=claude`        | 受理                                   |
| `-pclaude`         | **拒否** (`Unknown option '-pclaude'`) |
| `--profile=claude` | 受理                                   |
| `-a one -a two`    | 受理 (配列として順序保持)              |

`NameSpecification.short` の既定は `allowingJoined: false` (`Sources/ArgumentParser/Parsable Properties/NameSpecification.swift:78`) であり、結合表記は受理されない。

**帰結**: `ProfileDispatch.buildExecArguments` が除去すべき表記は `--profile` / `--profile=<v>` / `-p` / `-p=<v>` の4形態で**網羅できる**。ただしこれは `allowingJoined` を有効化しないことが前提であり、有効化すると除去ロジックが不完全になり F2 (exec 無限ループ) が再発する。この前提を設計上の不変条件として明記する。

### R-3: `CompletionShell` の引数受理 — 解決

`CompletionShell` は `RawRepresentable` / `Hashable` / `CaseIterable` / `Sendable` に適合するが、`ExpressibleByArgument` には**適合していない** (`Sources/ArgumentParser/Completions/CompletionsGenerator.swift:15`)。`@Argument` として直接受けるには、本リポジトリ側で `extension CompletionShell: ExpressibleByArgument` を宣言する。`init?(rawValue:)` が `zsh` / `bash` / `fish` 以外を `nil` にするため、`ExpressibleByArgument` の既定実装 (`init?(argument:)` → `init?(rawValue:)`) がそのまま Req 8.3 の拒否になる。`allValueStrings` は `allCases` から導ける。

### R-4 (新規): `parseAsRoot` の擬似コマンド扱い — 解決

`--generate-completion-script` は通常のオプションではなく、`CommandParser.checkForCompletionScriptRequest` が `CommandError(.completionScriptRequested)` を **throw** することで処理される (`Sources/ArgumentParser/Parsing/CommandParser.swift:442-478`)。`--help` / `--version` も同様に throw 系の制御フローで扱われる。

**帰結**: `YobirinCommand.parseAsRoot(arguments)` の結果を次のように解釈すれば、コマンド種別の判定が引数の位置走査なしで完結する。

- 成功して `NotifyCommand` が返る → 通知の配信要求 (バンドル必須)
- 成功して `DoctorCommand` が返る → 診断要求 (バンドルが望ましいが必須ではない)
- 成功して `SweepCommand` が返る → 掃除要求 (バンドル必須)
- 成功してそれ以外が返る → バンドル不要
- throw する (ヘルプ / バージョン / 補完 / 引数エラー) → バンドル不要

これは F1 (オプション値の誤認) と F5 (補完が許可リストに無い) を**同時に**解消する。許可リストという別管理の表を持たずに済むため、サブコマンドを追加するたびにリストを更新し忘れる構造的な穴も閉じる。

## D2. 設計上の主要判断

### DD-1: 起動ゲートの判定基盤を `parseAsRoot` へ移す

**採用**。代替案は「許可リストに `completion` / `doctor` / `sweep` を追加し、位置走査を『オプションの値を飛ばす』ように賢くする」だったが、これは ArgumentParser の引数文法 (短縮形・`=` 区切り・配列オプション・`--` 終端) を二重実装することを意味し、F1 と同種の乖離を将来また生む。パーサに判定させるのが唯一の一貫した解。

`parseAsRoot` は通知APIに触れないため、バンドル外で安全に呼べる。副作用は引数の解釈のみ。

**制約**: 判定は `NSApplication` / `UserNotifications` に触れる前に完了していなければならない。`parseAsRoot` は `ParsableCommand` インスタンスを生成するが `run()` は呼ばないため、この制約は満たされる。

### DD-2: `sweep` サブコマンドの新設

Req 12.1 で引数なし・対話時にヘルプを表示すると、README が案内している復旧手順「引数なしで `yobirin` を起動すると孤児通知が掃除される」が端末から機能しなくなる。復旧手段を失わせないため、明示的な `sweep` サブコマンドを新設する (Req 12.3〜12.6)。

これは当初のUX改善リストに無かった追加だが、Req 12.1 を入れる以上、代替手段の提供は同一specの責任範囲に入る。

### DD-3: `doctor` を通知系コマンドとして扱う (import 規律の例外)

`structure.md` は「インストール系 (`install` / `list` / ヘルプ) は通知APIの型に一切触れず、素のバイナリで完走する」を機械確認可能な不変条件として定めている。`doctor` は通知許可の状態 (Req 15.4) を報告するため `UserNotifications` に触れざるを得ない。

**判断**: `doctor` を通知系コマンドとして分類する。既存の不変条件は `install` / `uninstall` / `list` / `ps` / `completion` について維持する。`doctor` はバンドル外でも起動できなければならない (Req 15.5) ため、通知APIの**呼び出し**はバンドル内であることを実行時に確認してから行う。import しているだけでは例外は発生せず、`UNUserNotificationCenter.current()` の呼び出しが例外を投げる (steering tech.md 制約1) ため、この分岐で安全性は担保できる。

steering の `structure.md` は本spec完了後に追随更新が必要 (本specの成果物ではない)。

### DD-4: タイムアウト変換規則の単一ソース化

Req 4 (notify のパース) と Req 14.3〜14.4 (ps の argv 解釈) が同じ変換規則を要求する。`ps` は通知API非依存でなければならない (Req 14.9) ため、変換は Foundation のみに依存する純粋関数として切り出し、両者が参照する。`structure.md` の「命名規約は `ProfileNaming` が単一ソース」と同じ方針。

### DD-5: 端末接続判定の単一化

`isatty` に基づく判定が3箇所で必要になる。

| 要件        | 対象                                             |
| ----------- | ------------------------------------------------ |
| 5.3         | 標準入力が端末か (stdin から読んでよいか)        |
| 12.1 / 12.2 | 標準入力・標準出力・標準エラーのいずれかが端末か |
| 13.1 / 13.2 | 標準エラーが端末か                               |

判定対象が異なるため単一の真偽値には畳めない。ファイルディスクリプタを受けて真偽を返す薄い述語を1つ用意し、注入点をそこへ集約する。テストは述語を差し替えて行う。

## D3. 合成 (design-synthesis)

- **一般化**: DD-4 (タイムアウト変換) と DD-5 (端末判定) は、いずれも複数要件が同じ規則を要求する箇所であり、共有部品として切り出す。それ以外に共通化の余地は見つからなかった。特に「終了コード決定」と「`--print` の値抽出」は同じ結果値を入力にするが、出力先も型も異なるため統合しない。
- **Build vs Adopt**: 補完スクリプトの生成は依存ライブラリの `completionScript(for:)` をそのまま採用する (Build しない)。`CompletionShell` の `ExpressibleByArgument` 適合のみ本リポジトリで宣言する。
- **簡素化**: F2 の対策として「環境変数によるディスパッチ済みフラグ」を検討したが、argv に現れない隠れ状態を導入するため不採用。R-2 で除去すべき表記が4形態に限定されることが確定したため、既存の除去方式の拡張で十分と判断した。
- **簡素化**: `doctor` の通知許可判定を子プロセス起動で行う案 (バンドルを別プロセスとして実行) を検討したが、実行時の分岐で足りるため不採用。

## D4. リスクと軽減

| リスク                            | 影響                                                                    | 軽減                                                                                                                 |
| --------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `parseAsRoot` の二重パース        | 起動ゲートと `YobirinCommand.main()` で2回パースする                    | パースは副作用を持たない。性能影響はワンショットCLIでは無視できる                                                    |
| `allowingJoined` の将来的な有効化 | F2 (exec 無限ループ) の再発                                             | 除去対象の網羅性がこの前提に依存することを設計・コメント・テストに明記する                                           |
| `isatty` による誤判定             | 引数なし実行が対話と誤判定され孤児通知が残る / 逆に端末でヘルプが出ない | 誤判定時の被害は「掃除されない」か「ヘルプが出ない」のいずれかで、いずれも `sweep` / `--help` の明示指定で回避できる |
| `ps` のタイムアウト表示形式の変更 | 既存の `TIMEOUT` 列が `300` から人間可読形式へ変わる                    | テキスト出力は人間向けであり、機械可読が必要な利用者は `--json` の `timeoutSeconds` を使う (Req 14.6)                |
| spec の規模                       | 15要件・広い変更範囲で一括レビューが困難                                | タスクフェーズで独立性の高い群 (起動経路 / 引数 / 出力契約 / 診断) に分割する                                        |
