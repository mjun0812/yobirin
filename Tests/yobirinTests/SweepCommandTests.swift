import UserNotifications
import XCTest

@testable import yobirin

/// - Note (SDK制約): `UNNotification` はテストコードから直接構築できないため、モックの
///   `getDeliveredNotifications` は常に空配列を返す。したがって「0件以外の件数が表示に反映
///   されること」は自動テストできない (`LaunchGuardTests` が既に同じ制約を記録している)。
///   ここでは0件時の表示形式と、削除呼び出しが1回だけ走ることを固定する。
private final class MockNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private(set) var requestAuthorizationCallCount = 0
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removeDeliveredCalls: [[String]] = []
    private(set) var getDeliveredNotificationsCallCount = 0

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        requestAuthorizationCallCount += 1
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removeDeliveredCalls.append(identifiers)
    }

    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
    }

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        getDeliveredNotificationsCallCount += 1
        DispatchQueue.global().async {
            completionHandler([])
        }
    }

    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {}
}

/// `@Sendable` なcompletionから結果を受け取るためのロック付きボックス
/// (LaunchGuardTests.Recorder と同じ発想)。
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ initialValue: Value) {
        storedValue = initialValue
    }

    func set(_ newValue: Value) {
        lock.lock()
        storedValue = newValue
        lock.unlock()
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

final class SweepCommandTests: XCTestCase {
    // MARK: - 削除件数を返す掃除処理 (Requirement 12.3)

    func testSweepReportsTheNumberOfRemovedNotifications() throws {
        let client = MockNotificationCenterClient()
        let count = Recorder<Int?>(nil)

        LaunchGuard.sweepDeliveredNotifications(client: client) { count.set($0) }

        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(client.getDeliveredNotificationsCallCount, 1)
        XCTAssertEqual(client.removeDeliveredCalls, [[]])
    }

    /// 掃除は通知を配信しない (引数なし起動の既存契約と同じ。Requirement 6.2 を壊さない)。
    func testSweepNeverDeliversANotification() throws {
        let client = MockNotificationCenterClient()
        let finished = Recorder<Bool>(false)

        LaunchGuard.sweepDeliveredNotifications(client: client) { _ in finished.set(true) }

        XCTAssertTrue(finished.value)
        XCTAssertEqual(client.requestAuthorizationCallCount, 0)
        XCTAssertTrue(client.addedRequests.isEmpty)
    }

    // MARK: - サブコマンドとしての振る舞い (Requirements 12.4, 12.5)

    func testPerformReportsTheRemovedCount() throws {
        let client = MockNotificationCenterClient()
        let written = Recorder<[String]>([])
        let exitCodes = Recorder<[Int32]>([])

        SweepCommand.perform(
            client: client,
            stdoutWriter: { written.set(written.value + [$0]) },
            exit: { exitCodes.set(exitCodes.value + [$0]) }
        )

        XCTAssertEqual(written.value, ["Removed 0 delivered notification(s)"])
        XCTAssertEqual(exitCodes.value, [0])
    }

    func testPerformRemovesDeliveredNotifications() throws {
        let client = MockNotificationCenterClient()
        let finished = Recorder<Bool>(false)

        SweepCommand.perform(
            client: client,
            stdoutWriter: { _ in },
            exit: { _ in finished.set(true) }
        )

        XCTAssertTrue(finished.value)
        XCTAssertEqual(client.removeDeliveredCalls.count, 1)
    }

    /// 掃除完了より前にexitしないこと (fire-and-forgetでexitすると掃除が走る前にプロセスが死ぬ)。
    func testPerformRemovesBeforeExiting() throws {
        let client = MockNotificationCenterClient()
        let removeCountAtExitTime = Recorder<Int>(-1)

        SweepCommand.perform(
            client: client,
            stdoutWriter: { _ in },
            exit: { _ in removeCountAtExitTime.set(client.removeDeliveredCalls.count) }
        )

        XCTAssertEqual(removeCountAtExitTime.value, 1)
    }
}
