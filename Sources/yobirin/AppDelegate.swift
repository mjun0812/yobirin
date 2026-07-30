import AppKit
import UserNotifications

/// `NSApplication` + AppDelegate方式による起動の薄い配線層 (design.md AppLifecycle /
/// File Structure Plan)。`RunLoop.main.run()` だけでは `applicationDidFinishLaunching` が来ず
/// 通知許可が取れないため、この方式が必須 (steering tech.md 絶対に守る制約 6)。
///
/// 認可・配信・タイマー・timeout確定・出力決定のオーケストレーションは `AppFlow` /
/// `NotificationSession` に置き、このクラスは次の2つのみを担う (テスト不能なNSApplication配線を
/// 薄く保つ。design.md 2層構成):
/// - `applicationDidFinishLaunching` からの `AppFlow.start` 起動
/// - `UNUserNotificationCenterDelegate` コールバックの `NotificationSession` への転送
///
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let request: NotificationRequest
    private let session: NotificationSession
    private let appFlow: AppFlow

    /// - Parameter outputPolicy: 結果確定時の出力表現と終了コードの方針 (Requirements 1, 2, 3)。
    ///   既定は従来どおり「JSON全体 + exit 0」。認可失敗・配信失敗の経路 (`AppFlow` の
    ///   `onOutput` 直行) には影響しない — それらは既存の予約コードを使う (Requirements 1.6, 1.7)。
    init(
        request: NotificationRequest,
        client: NotificationCenterClient,
        outputPolicy: OutputPolicy = .default,
        onOutput: @escaping (EmittedOutput) -> Void
    ) {
        self.request = request
        self.session = NotificationSession(
            client: client,
            actions: request.actions,
            onResult: { result in
                onOutput(
                    ResultEmitter.forResult(
                        ResultOutput(result: result, deliveredAt: nil), policy: outputPolicy))
            }
        )
        self.appFlow = AppFlow(
            client: client,
            session: self.session,
            scheduler: DispatchQueueScheduler.schedule,
            onOutput: onOutput
        )
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appFlow.start(request)
    }

    /// `CancellationSignal` からの転送口 (design.md CancellationSignal、Requirements 2.5〜2.7)。
    /// `session` がprivateのため、`NotifyCommand.run()` から直接 `session.handleCancel()` を
    /// 呼べない。この薄い転送のみを担う。
    func handleCancel() {
        session.handleCancel()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        session.handleResponse(
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText
        )
        completionHandler()
    }

    /// フォアグラウンド (アプリ実行中) でも通知をバナー表示させる。yobirinはワンショットで
    /// 常時実行中のため、これがないと通知が表示されないまま応答を待ち続けてしまう。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
