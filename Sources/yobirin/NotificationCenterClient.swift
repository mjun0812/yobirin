import UserNotifications

/// `UNUserNotificationCenter` の操作を抽象化するプロトコル。
///
/// `UNUserNotificationCenter.current()` は署名済み `.app` バンドル外
/// (swift testの実行環境) では `bundleProxyForCurrentProcess is nil` で例外死するため、
/// `NotificationSession` はこのプロトコルを介して通知センターを操作し、
/// テストはモック実装に対して行う (design.md NotificationSession)。
protocol NotificationCenterClient {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest, completionHandler: (@Sendable (Error?) -> Void)?)
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void)
}

/// 実センターへの薄い橋渡し。`UNUserNotificationCenter.current()` はバンドル外で例外死するため
/// swift testでは使えず、実配線とスモーク確認は task 3.1/4.1 の範囲とする。
final class UNNotificationCenterAdapter: NotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest, completionHandler: (@Sendable (Error?) -> Void)?) {
        center.add(request, withCompletionHandler: completionHandler)
    }

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        center.getDeliveredNotifications(completionHandler: completionHandler)
    }
}
