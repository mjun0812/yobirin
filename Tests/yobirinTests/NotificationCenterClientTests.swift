import UserNotifications
import XCTest

@testable import yobirin

/// `UNNotificationCenterAdapter` の遅延評価化を検証する (design.md
/// 「NotificationCenterClientのcenterは遅延評価へ修正」、Requirement 12.1)。
///
/// - Note (RED phase evidence): 修正前の `UNNotificationCenterAdapter` は
///   `private let center = UNUserNotificationCenter.current()` という非lazyな格納プロパティを持ち、
///   `init()` の時点で `UNUserNotificationCenter.current()` へ到達していた。素のMach-O
///   (署名済み.appバンドル外。swift testの実行環境はこれに該当する) では
///   `bundleProxyForCurrentProcess is nil` によりSIGABRTでプロセスごと落ちるため、
///   本テストは修正前は失敗ではなくクラッシュとして観測される
///   (`swift test --filter NotificationCenterClientTests` 実行時にテストプロセスがSIGABRTで終了する)。
final class NotificationCenterClientTests: XCTestCase {
    func testAdapterCanBeInstantiatedOutsideABundleWithoutCrashing() {
        // インスタンス化だけでは `UNUserNotificationCenter.current()` に到達しないこと
        // (型に触れただけではセンターへアクセスしない遅延評価) を確認する。
        let adapter: NotificationCenterClient = UNNotificationCenterAdapter()

        XCTAssertTrue(adapter is UNNotificationCenterAdapter)
    }

    // MARK: - 許可状態の読み取り (Requirement 15.4)

    /// `doctor` は許可を要求せずに状態だけを読む必要がある。要求してしまうと診断のたびに
    /// 許可ダイアログが出る (design.md DoctorCommand)。プロトコルに読み取り専用の窓口があり、
    /// モックから任意の状態を注入できることを検証する。
    func testAuthorizationStatusCanBeInjectedThroughTheProtocol() {
        let statuses: [UNAuthorizationStatus] = [.notDetermined, .denied, .authorized]

        for status in statuses {
            let client: NotificationCenterClient = StubAuthorizationStatusClient(status: status)
            let expectation = expectation(description: "status delivered")
            // completionHandler が `@Sendable` のため、可変ローカル変数は捕捉できない
            // (LaunchGuardTests.Recorder と同じ発想でロック付きボックスを使う)。
            let received = ReceivedStatus()

            client.getAuthorizationStatus { value in
                received.set(value)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 1)
            XCTAssertEqual(received.value, status)
        }
    }

    /// 状態の読み取りが既存の認可要求経路を呼ばないこと (Requirement 15.4 の「要求しない」)。
    func testReadingStatusDoesNotRequestAuthorization() {
        let client = StubAuthorizationStatusClient(status: .denied)
        let expectation = expectation(description: "status delivered")

        client.getAuthorizationStatus { _ in expectation.fulfill() }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(client.requestAuthorizationCallCount, 0)
    }
}

/// `@Sendable` なcompletionHandlerから結果を受け取るためのロック付きボックス。
private final class ReceivedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UNAuthorizationStatus?

    func set(_ newValue: UNAuthorizationStatus) {
        lock.lock()
        storedValue = newValue
        lock.unlock()
    }

    var value: UNAuthorizationStatus? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

/// 許可状態のみを注入できる最小のスタブ。他のメソッドは呼ばれない想定で空実装とする。
private final class StubAuthorizationStatusClient: NotificationCenterClient, @unchecked Sendable {
    private let status: UNAuthorizationStatus
    private(set) var requestAuthorizationCallCount = 0

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        requestAuthorizationCallCount += 1
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {}

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {}

    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        let status = status
        DispatchQueue.global().async {
            completionHandler(status)
        }
    }
}
