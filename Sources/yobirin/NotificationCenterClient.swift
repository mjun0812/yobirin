import UserNotifications

/// `UNUserNotificationCenter` の操作を抽象化するプロトコル。
///
/// `UNUserNotificationCenter.current()` は署名済み `.app` バンドル外
/// (swift testの実行環境) では `bundleProxyForCurrentProcess is nil` で例外死するため、
/// `NotificationSession` はこのプロトコルを介して通知センターを操作し、
/// テストはモック実装に対して行う (design.md NotificationSession)。
protocol NotificationCenterClient {
    func requestAuthorization(completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest, completionHandler: (@Sendable (Error?) -> Void)?)
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void)

    /// 通知許可の状態を**読み取る**だけの窓口 (Requirement 15.4)。
    ///
    /// `doctor` はこれのみを使う。`requestAuthorization` を診断に使ってはならない — 呼ぶと
    /// 診断のたびに許可を要求することになり、未許可の初回は許可ダイアログが出る
    /// (design.md DoctorCommand)。`UNNotificationSettings` 全体ではなく
    /// `UNAuthorizationStatus` だけを渡すのは、値型 (Sendable) のまま境界を越えられるため。
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void)
}

/// 実センターへの薄い橋渡し。`center` は算出プロパティとして遅延評価するため、型の参照や
/// インスタンス化だけではバンドル外でも例外死しない (Requirement 12.1)。ただしメソッド呼び出し
/// 自体は `UNUserNotificationCenter.current()` へ到達しバンドル内実行を前提とするため、
/// swift testでは使えず、実配線とスモーク確認は task 3.1/4.1 の範囲とする。
final class UNNotificationCenterAdapter: NotificationCenterClient {
    // `.current()` は毎回呼んでもシングルトン取得でしかなくコストは無視できるため、
    // `lazy var` ではなく computed property で遅延評価する (design.md NotificationCenterClient)。
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization(completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        center.requestAuthorization(options: [.alert, .sound], completionHandler: completionHandler)
    }

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

    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completionHandler(settings.authorizationStatus)
        }
    }
}
