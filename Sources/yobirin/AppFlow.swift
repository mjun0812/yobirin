import Foundation

/// 認可→配信→タイマー→timeout確定→出力決定のオーケストレーション (design.md AppLifecycle、
/// Requirements 5.1-5.4, 7.1-7.3)。
///
/// `NSApplication` / `AppDelegate` の実配線 (テスト不能領域) から切り離し、モックの
/// `NotificationCenterClient` と `Scheduler` に対してテストできるコア型として設計する。
/// `NotificationSession` は構築済みのものを外部から受け取る (応答の判別・排他確定・
/// timeout時の通知削除は `NotificationSession` 側の責務のまま。ここで二重に排他機構は作らない)。
final class AppFlow: @unchecked Sendable {
    private let client: NotificationCenterClient
    private let session: NotificationSession
    private let scheduler: Scheduler
    private let onOutput: (EmittedOutput) -> Void

    /// タイムアウトタイマーのハンドル。破棄されないよう保持する。
    /// `handleAuthorization` (認可コールバック) からのみ書き込まれ、
    /// 認可完了より前にタイマーが読まれることはないため安全 (Requirement 5.4)。
    private var timeoutCancellable: Cancellable?

    init(
        client: NotificationCenterClient,
        session: NotificationSession,
        scheduler: @escaping Scheduler,
        onOutput: @escaping (EmittedOutput) -> Void
    ) {
        self.client = client
        self.session = session
        self.scheduler = scheduler
        self.onOutput = onOutput
    }

    /// 通知許可を要求し、完了後に配信とタイマー開始を行う (Requirement 5.1, 7.1)。
    func start(_ request: NotificationRequest) {
        client.requestAuthorization { [weak self] granted, error in
            self?.handleAuthorization(granted: granted, error: error, request: request)
        }
    }

    /// 許可なし (error / granted == false の両経路) はここでexit 2相当の出力を確定する
    /// (Requirement 7.2)。許可ありの場合のみ配信し、`--timeout` 指定時のみタイマーを
    /// 開始する (Requirements 5.3, 5.4)。
    private func handleAuthorization(granted: Bool, error: Error?, request: NotificationRequest) {
        if let error {
            onOutput(ResultEmitter.forPermissionDenied(reason: "Failed to obtain notification permission: \(error)"))
            return
        }
        guard granted else {
            onOutput(ResultEmitter.forPermissionDenied(reason: "Notifications are not permitted"))
            return
        }

        do {
            try session.deliver(request)
        } catch {
            onOutput(ResultEmitter.forEnvironmentError("Failed to deliver the notification: \(error)"))
            return
        }

        if let timeout = request.timeout {
            timeoutCancellable = scheduler(timeout) { [weak self] in
                self?.session.handleTimeout()
            }
        }
    }
}
