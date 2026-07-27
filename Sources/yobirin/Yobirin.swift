import ArgumentParser
import Foundation

/// プロセスの実エントリポイント。引数なしガード (design.md AppLifecycle、
/// Requirements 6.2, 6.3) はArgumentParserより先に効かなければならないため、
/// `@main` はここに置き、`YobirinCommand` 側には付けない。
@main
enum YobirinMain {
    static func main() {
        if LaunchGuard.isArgumentlessLaunch(CommandLine.arguments) {
            LaunchGuard.cleanUpAndExit(client: UNNotificationCenterAdapter(), exit: { exit($0) })
        } else {
            YobirinCommand.main()
        }
    }
}

/// ルートコマンド。サブコマンド構成に再編し、通知送信は既定サブコマンド `NotifyCommand` へ
/// 分離する (design.md CLI契約)。従来の `yobirin --title <str> --message <str> ...` は
/// `defaultSubcommand` によりそのまま `NotifyCommand` へ解決され、互換を保つ
/// (Requirement 11.8)。
struct YobirinCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [NotifyCommand.self],
        defaultSubcommand: NotifyCommand.self
    )
}
