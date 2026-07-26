import Foundation

/// 通知への応答結果 (design.md Data Models > 出力JSON契約)
enum NotificationResult: Equatable {
    case clicked
    case action(label: String, index: Int)
    case replied(text: String)
    case dismissed
    case timeout
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
        case .clicked, .dismissed, .timeout:
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

    private var resultName: String {
        switch result {
        case .clicked: return "clicked"
        case .action: return "action"
        case .replied: return "replied"
        case .dismissed: return "dismissed"
        case .timeout: return "timeout"
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
    let text: String
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

    /// ユーザー応答またはtimeoutで確定した結果 → stdoutへJSON、exit 0
    static func forResult(_ output: ResultOutput) -> EmittedOutput {
        EmittedOutput(destination: .stdout, text: output.jsonString(), exitCode: 0)
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
