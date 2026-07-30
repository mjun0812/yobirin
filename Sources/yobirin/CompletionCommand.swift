import ArgumentParser
import Foundation

/// `completion` サブコマンドの引数定義と補完スクリプトの出力 (design.md CompletionCommand、
/// Requirements 8.1, 8.2, 8.3, 8.8)。
///
/// 生成そのものはswift-argument-parserの `completionScript(for:)` に委譲し、自前の生成は
/// 持たない。通知APIやAppKitの型に一切触れないため、バンドル外の素のMach-Oからでも完走する
/// (Requirement 8.8)。
struct CompletionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Print the shell completion script for yobirin"
    )

    @Argument(help: "Shell to generate the completion script for (\(CompletionCommand.supportedShellList))")
    var shell: String

    /// 未対応のシェル名を、補完スクリプトを出力する前に拒否する (Requirement 8.3)。
    func validate() throws {
        _ = try Self.parseShell(shell)
    }

    func run() throws {
        Self.perform(shell: try Self.parseShell(shell), stdoutWriter: Self.defaultStdoutWriter)
    }

    /// 受理するシェル名の一覧。swift-argument-parser が対応する範囲をそのまま単一ソースとして
    /// 参照し、こちら側で列挙を複製しない (research.md R-3)。
    static var supportedShellList: String {
        CompletionShell.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// シェル名の解決 (Requirements 8.2, 8.3)。`CompletionShell.init?(rawValue:)` が
    /// `zsh` / `bash` / `fish` 以外を `nil` にするため、限定と拒否の双方がこれで満たされる。
    ///
    /// - Note: `CompletionShell` を直接 `@Argument` として受けるには
    ///   `ExpressibleByArgument` への retroactive conformance が必要になるが、本リポジトリの
    ///   swift-format 設定 (`AvoidRetroactiveConformances`) がそれを禁じている。そのため
    ///   文字列で受けてここで解決する。
    static func parseShell(_ value: String) throws -> CompletionShell {
        guard let shell = CompletionShell(rawValue: value) else {
            throw ValidationError("Unsupported shell '\(value)'. Supported shells: \(supportedShellList)")
        }
        return shell
    }

    /// 補完スクリプトの生成と出力 (Requirement 8.1)。`stdoutWriter` を注入してテストする
    /// (`ListCommand` / `PsCommand` と同じ方針)。
    ///
    /// 対象はルートコマンド (`YobirinCommand`) であり、このサブコマンド自身ではない。
    /// 利用者が補完したいのは `yobirin ...` の入力全体のため。
    static func perform(shell: CompletionShell, stdoutWriter: (String) -> Void) {
        stdoutWriter(YobirinCommand.completionScript(for: shell))
    }

    private static func defaultStdoutWriter(_ text: String) {
        print(text)
    }
}
