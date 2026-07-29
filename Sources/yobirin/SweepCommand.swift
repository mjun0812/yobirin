import ArgumentParser
import Darwin
import Dispatch
import Foundation

/// `sweep` サブコマンドの引数定義と孤児通知の削除 (design.md SweepCommand、
/// Requirements 12.3, 12.4, 12.5)。
///
/// 引数なし起動でヘルプを表示するようにした結果 (Requirement 12.1)、READMEが案内していた
/// 「引数なしで起動すると孤児通知が掃除される」という復旧手順が端末から使えなくなる。
/// その代替として、明示的な掃除の窓口を提供する (research.md DD-2)。
///
/// 削除処理そのものは `LaunchGuard.sweepDeliveredNotifications` を共有し、引数なし起動の
/// 経路と実装を重複させない。標準ストリームの接続状態は参照しない — 端末かどうかに関わらず
/// 削除する (Requirement 12.4)。
struct SweepCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sweep",
        abstract: "Remove delivered notifications left behind by interrupted yobirin processes"
    )

    func run() {
        Self.perform(
            client: UNNotificationCenterAdapter(),
            stdoutWriter: Self.defaultStdoutWriter,
            exit: { Darwin.exit($0) }
        )
    }

    /// 掃除 → 件数の報告 → 終了、の結線 (Requirement 12.5)。`client` / `stdoutWriter` /
    /// `exit` を注入してテストする。
    ///
    /// `stdoutWriter` と `exit` が `@Sendable` なのは、`sweepDeliveredNotifications` の
    /// completion がUNのバックグラウンド完了から呼ばれるため。掃除の完了前にexitしない契約は
    /// `LaunchGuard` 側が保証する。
    static func perform(
        client: NotificationCenterClient,
        timeout: DispatchTimeInterval = .seconds(2),
        stdoutWriter: @escaping @Sendable (String) -> Void,
        exit: @escaping @Sendable (Int32) -> Void
    ) {
        LaunchGuard.sweepDeliveredNotifications(client: client, timeout: timeout) { removedCount in
            stdoutWriter("Removed \(removedCount) delivered notification(s)")
            exit(0)
        }
    }

    private static let defaultStdoutWriter: @Sendable (String) -> Void = { text in
        print(text)
        fflush(stdout)
    }
}
