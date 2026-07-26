import Dispatch
import UserNotifications

/// 引数なし起動への防御 (design.md AppLifecycle / Error Handling > 再起動・孤児通知への防御、
/// Requirements 6.2, 6.3)。
///
/// SIGKILL等の異常終了後に残った孤児の配信済み通知がクリックされると、通知は引数なしで
/// .appを再起動させる。この経路を塞ぐため、引数なし起動時は通知を配信せず、応答待ちの主が
/// いない配信済み通知を掃除してから即exitする (遅延なし。`ExitCoordinator` の遅延exitとは別経路)。
enum LaunchGuard {
    /// 実行ファイル名のみ (要素数1以下) を「引数なし起動」と判定する純粋関数。
    ///
    /// `--help` や不正引数の扱いはswift-argument-parserの領分であり、このガードは
    /// 「引数ゼロ」のみを対象とする。
    static func isArgumentlessLaunch(_ arguments: [String]) -> Bool {
        arguments.count <= 1
    }

    /// 通知を配信せず、`getDeliveredNotifications` で取得した配信済み通知(このバンドルのもの
    /// しか見えない)を全て削除してから即exit(0)する。
    ///
    /// 掃除完了後にexitすること(fire-and-forgetでexitすると掃除が走る前にプロセスが死ぬ)を
    /// 保証するため、`removeDeliveredNotifications` の呼び出しと `exit` は
    /// `getDeliveredNotifications` の completionHandler 内で順に行う。呼び出し元
    /// (`YobirinMain.main()`)は本関数がreturnした直後にプロセスをexitさせうるため、
    /// この非同期completionが完了するまで本関数自体を同期的にブロックする。
    ///
    /// 実プロセスではcompletion内の実 `exit(0)` がプロセスを終了させるため、以降の
    /// `finished.signal()` には到達しない (それで正しい)。`timeout` はUN側の稀なハング
    /// への保険であり、Requirement 6.2の「即終了」を損なわない値 (デフォルト2秒)。
    static func cleanUpAndExit(
        client: NotificationCenterClient,
        timeout: DispatchTimeInterval = .seconds(2),
        exit: @escaping @Sendable (Int32) -> Void
    ) {
        let finished = DispatchSemaphore(value: 0)
        DeliveredNotificationSweep(
            client: client,
            exit: { code in
                exit(code)
                finished.signal()
            }
        ).run()
        _ = finished.wait(timeout: .now() + timeout)
    }
}

/// `client` (`Sendable` に準拠しない `NotificationCenterClient` existential) を
/// `getDeliveredNotifications` の `@Sendable` completionHandler内で安全に捕捉するための
/// 薄いラッパー。`AppFlow` が同種の問題を `@unchecked Sendable` で解決しているのと同じパターン。
private final class DeliveredNotificationSweep: @unchecked Sendable {
    private let client: NotificationCenterClient
    private let exit: (Int32) -> Void

    init(client: NotificationCenterClient, exit: @escaping (Int32) -> Void) {
        self.client = client
        self.exit = exit
    }

    func run() {
        client.getDeliveredNotifications { notifications in
            let identifiers = notifications.map { $0.request.identifier }
            self.client.removeDeliveredNotifications(withIdentifiers: identifiers)
            self.exit(0)
        }
    }
}
