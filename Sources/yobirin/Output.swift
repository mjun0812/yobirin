import ArgumentParser
import Foundation

/// `--print` が受け付ける出力対象フィールド (design.md OutputPolicy / PrintField、
/// Requirements 2.2, 2.3)。
///
/// `String` RawValue の列挙型を `ExpressibleByArgument` に適合させることで、4種類への限定と
/// それ以外の拒否が引数解析の段階で成立する。追加の検証コードを書かない。
/// 出力形式の指定・テンプレート展開・複数フィールドの同時指定は受け付けない (Requirement 2.7。
/// jqを追い出した先で自前のミニ言語を抱えないため、この型は単一フィールドの選択以上に育てない)。
enum PrintField: String, CaseIterable, ExpressibleByArgument {
    case result
    case action
    case actionIndex
    case text
}

/// 結果の出力表現と終了コードの決定方針 (design.md OutputPolicy、Requirements 1, 2, 3)。
///
/// `NotifyCommand` が構築し、`AppDelegate` を経て `ResultEmitter` まで読み取り専用で渡る。
/// 既定値 (`.default`) のときの振る舞いは変更前の実装と完全に一致する (Requirements 1.5, 2.6)。
struct OutputPolicy: Equatable {
    var exitCodeEnabled: Bool
    var printField: PrintField?

    /// 既存の振る舞い: 結果JSON全体を出力し、常に exit 0。
    static let `default` = OutputPolicy(exitCodeEnabled: false, printField: nil)
}

/// 通知への応答結果 (design.md Data Models > 出力JSON契約)
enum NotificationResult: Equatable {
    case clicked
    case action(label: String, index: Int)
    case replied(text: String)
    case dismissed
    case timeout
    case canceled
}

/// 結果JSON全体。`result` 本体と、任意で付与できる `deliveredAt` を持つ。
struct ResultOutput: Equatable {
    var result: NotificationResult
    var deliveredAt: Date?

    /// design.md 出力JSON契約に従うJSON文字列を生成する。
    ///
    /// キー順は常に `result` → 種別固有フィールド → `deliveredAt` の安定した順序になる
    /// (テスト容易性のため、辞書ではなくキー・値のペア列から組み立てる)。
    func jsonString() -> String {
        var pairs: [(String, String)] = [("result", Self.jsonString(resultName))]

        switch result {
        case .clicked, .dismissed, .timeout, .canceled:
            break
        case .action(let label, let index):
            pairs.append(("action", Self.jsonString(label)))
            pairs.append(("actionIndex", String(index)))
        case .replied(let text):
            pairs.append(("text", Self.jsonString(text)))
        }

        if let deliveredAt {
            let formatted = ISO8601DateFormatter().string(from: deliveredAt)
            pairs.append(("deliveredAt", Self.jsonString(formatted)))
        }

        let body = pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    /// 指定フィールドの生の値 (Requirements 2.1, 2.4, 2.5)。
    ///
    /// 結果種別に存在しないフィールド (例: `dismissed` に対する `.text`) は `nil`。
    /// JSONのクォート・エスケープは施さない — `$(...)` で受けた変数にそのまま入る値を返す。
    func value(for field: PrintField) -> String? {
        switch field {
        case .result:
            return resultName
        case .action:
            guard case .action(let label, _) = result else { return nil }
            return label
        case .actionIndex:
            guard case .action(_, let index) = result else { return nil }
            return String(index)
        case .text:
            guard case .replied(let text) = result else { return nil }
            return text
        }
    }

    private var resultName: String {
        switch result {
        case .clicked: return "clicked"
        case .action: return "action"
        case .replied: return "replied"
        case .dismissed: return "dismissed"
        case .timeout: return "timeout"
        case .canceled: return "canceled"
        }
    }

    /// 文字列をJSON文字列リテラルへエンコードする (エスケープ・UTF-8はJSONEncoderへ委譲)。
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let json = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return json
    }
}

/// 出力先 (design.md Error Handling > 終了コード)
enum OutputDestination: Equatable {
    case stdout
    case stderr
}

/// 出力先・出力内容・終了コードの決定結果。
struct EmittedOutput: Equatable {
    let destination: OutputDestination
    /// `nil` は「出力しない」を意味する (Requirement 2.4)。空文字列 (空行を出力する) とは
    /// 区別される。`--print` の指定フィールドが結果種別に存在しないときだけ `nil` になる。
    let text: String?
    let exitCode: Int32
}

/// 結果JSONの生成と終了コード決定 (design.md Components and Interfaces > ResultEmitter)
///
/// 「ユーザー応答はJSON + exit 0、許可なしはstderr + exit 2、環境エラーはJSONなし + 非0」
/// という区別を、実際のプロセスexitや書き込みから切り離した純粋関数として提供する。
enum ResultEmitter {
    /// 通知許可なし (design.md 終了コード表: `UNErrorDomain Code=1` / `granted == false` の両経路)
    static let permissionDeniedExitCode: Int32 = 2

    /// その他の環境エラー。2は許可なしに予約されているため、Unix慣習の汎用エラーコード1を使う。
    static let environmentErrorExitCode: Int32 = 1

    /// `--exit-code` 指定時の却下 (design.md 終了コード表。3は上記2つの予約と衝突しない最小値)
    static let dismissedExitCode: Int32 = 3

    /// `--exit-code` 指定時のタイムアウト
    static let timeoutExitCode: Int32 = 4

    /// `--exit-code` 指定時のキャンセル (SIGTERM による能動的な終了。design.md 終了コード表)
    static let canceledExitCode: Int32 = 5

    /// `--exit-code` 指定時のアクション。`10 + actionIndex` を返すための基準値。
    /// 予約コード (1, 2) や却下・タイムアウト (3, 4) と間隔を空け、将来の結果種別の追加余地を残す。
    static let actionExitCodeBase: Int32 = 10

    /// 結果種別 → 終了コードの対応 (Requirements 1.1〜1.4)。`--exit-code` 指定時のみ使われる。
    ///
    /// クリックと返信はいずれも0。両者の区別は `--print text` の値が空かどうかで付ける
    /// (requirements.md 確定済みの設計判断)。予約コード (未許可2 / 環境エラー1) は返さない。
    static func exitCode(for result: NotificationResult) -> Int32 {
        switch result {
        case .clicked, .replied:
            return 0
        case .action(_, let index):
            return actionExitCodeBase + Int32(index)
        case .dismissed:
            return dismissedExitCode
        case .timeout:
            return timeoutExitCode
        case .canceled:
            return canceledExitCode
        }
    }

    /// ユーザー応答またはtimeoutで確定した結果 → stdoutへ出力方針に従う内容と終了コード
    /// (Requirements 1, 2, 3)。
    ///
    /// `policy` 省略時 (既定) の戻り値は、方針導入前の実装と完全に一致する: JSON全体 + exit 0
    /// (Requirements 1.5, 2.6)。既存の呼び出しは無改修で従来の振る舞いを保つ。
    static func forResult(_ output: ResultOutput, policy: OutputPolicy = .default) -> EmittedOutput {
        let text: String?
        if let field = policy.printField {
            text = output.value(for: field)  // 存在しないフィールドは nil = 出力なし (2.4)
        } else {
            text = output.jsonString()
        }
        return EmittedOutput(
            destination: .stdout,
            text: text,
            exitCode: policy.exitCodeEnabled ? exitCode(for: output.result) : 0
        )
    }

    /// 通知許可なし → JSONなし、stderrへ理由、exit 2
    static func forPermissionDenied(reason: String) -> EmittedOutput {
        EmittedOutput(destination: .stderr, text: reason, exitCode: permissionDeniedExitCode)
    }

    /// その他の環境エラー → JSONなし、stderrへエラー内容、非0 (2以外)
    static func forEnvironmentError(_ message: String) -> EmittedOutput {
        EmittedOutput(destination: .stderr, text: message, exitCode: environmentErrorExitCode)
    }
}
