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

    /// 通知を配信せず、`getDeliveredNotificationIdentifiers` で取得した配信済み通知(このバンドルの
    /// もの しか見えない)を全て削除し、削除件数を `completion` へ渡す (Requirements 6.3, 12.3)。
    ///
    /// 掃除完了後に後続処理を行うこと(fire-and-forgetでexitすると掃除が走る前にプロセスが死ぬ)を
    /// 保証するため、`removeDeliveredNotifications` の呼び出しと `completion` は
    /// `getDeliveredNotificationIdentifiers` の completionHandler 内で順に行う。呼び出し元は本関数が
    /// returnした直後にプロセスをexitさせうるため、この非同期completionが完了するまで本関数
    /// 自体を同期的にブロックする。
    ///
    /// `completion` はバックグラウンド (UNのcompletionHandler) から呼ばれる。呼び出し元
    /// スレッド上で同期的には呼ばれない。
    ///
    /// 実プロセスでは `completion` 内の実 `exit` がプロセスを終了させるため、以降の
    /// `finished.signal()` には到達しない (それで正しい)。`timeout` はUN側の稀なハング
    /// への保険であり、Requirement 6.2の「即終了」を損なわない値 (デフォルト2秒)。
    static func sweepDeliveredNotifications(
        client: NotificationCenterClient,
        timeout: DispatchTimeInterval = .seconds(2),
        completion: @escaping @Sendable (Int) -> Void
    ) {
        let finished = DispatchSemaphore(value: 0)
        DeliveredNotificationSweep(
            client: client,
            completion: { removedCount in
                completion(removedCount)
                finished.signal()
            }
        ).run()
        _ = finished.wait(timeout: .now() + timeout)
    }

    /// 引数なし起動の経路 (Requirements 6.2, 6.3)。掃除して即exit(0)する。
    /// 削除件数は表示しない — この経路の出力先はLaunchServices経由の実行であり、読み手がいない。
    /// 件数を見せるのは明示的な `sweep` サブコマンドの役目 (Requirement 12.5)。
    static func cleanUpAndExit(
        client: NotificationCenterClient,
        timeout: DispatchTimeInterval = .seconds(2),
        exit: @escaping @Sendable (Int32) -> Void
    ) {
        sweepDeliveredNotifications(client: client, timeout: timeout) { _ in exit(0) }
    }
}

/// `client` (`Sendable` に準拠しない `NotificationCenterClient` existential) を
/// `getDeliveredNotificationIdentifiers` の `@Sendable` completionHandler内で安全に捕捉するための
/// 薄いラッパー。`AppFlow` が同種の問題を `@unchecked Sendable` で解決しているのと同じパターン。
private final class DeliveredNotificationSweep: @unchecked Sendable {
    private let client: NotificationCenterClient
    private let completion: (Int) -> Void

    init(client: NotificationCenterClient, completion: @escaping (Int) -> Void) {
        self.client = client
        self.completion = completion
    }

    func run() {
        client.getDeliveredNotificationIdentifiers { identifiers in
            self.client.removeDeliveredNotifications(withIdentifiers: identifiers)
            self.completion(identifiers.count)
        }
    }
}
