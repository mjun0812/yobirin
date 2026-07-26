import UserNotifications
import XCTest

@testable import yobirin

/// `NotificationCenterClient` のモック。`getDeliveredNotifications` は実UNの挙動
/// (バックグラウンドスレッドからの非同期コールバック) を模してバックグラウンドキューで発火する。
///
/// - Note: `UNNotification` は designated initializer が `NS_UNAVAILABLE` のため
///   テストコードから直接構築できない (SDK制約)。そのため `getDeliveredNotifications` は
///   常に空配列を返す。「配信済み通知が0件のときも掃除経路が正しく完了すること」
///   「実際に返された通知の数だけ削除識別子を作ること」は本モックの実装 (`notifications.map`)
///   がidentifier抽出そのものであり、空配列以外のフィクスチャでの検証はSDK制約によりできない
///   (CONCERNSに記録)。
private final class MockNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private(set) var requestAuthorizationCallCount = 0
    private(set) var setCategoriesCalls: [Set<UNNotificationCategory>] = []
    private(set) var removeDeliveredCalls: [[String]] = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var getDeliveredNotificationsCallCount = 0

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        requestAuthorizationCallCount += 1
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        setCategoriesCalls.append(categories)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removeDeliveredCalls.append(identifiers)
    }

    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        getDeliveredNotificationsCallCount += 1
        DispatchQueue.global().async {
            completionHandler([])
        }
    }
}

/// `getDeliveredNotifications` の completionHandler を一切呼び出さないモック。
/// UN側が稀にハングするケース (Apple Forums 746045) を模し、`cleanUpAndExit` の
/// `timeout` が上限として機能することを検証するために使う。
private final class NeverCompletingNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {}

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {}

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        // 意図的にcompletionHandlerを呼ばない (ハングを再現)。
    }
}

/// `cleanUpAndExit` の `exit` は `@Sendable` が要求されるため、背景スレッドから記録する
/// テスト結果はロックで保護したこのボックス経由で読み書きする
/// (NotificationSessionTests.testConcurrentResponsesCommitExactlyOnce と同じ発想)。
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

final class LaunchGuardTests: XCTestCase {
    // MARK: - Argumentless launch detection is a pure function (Requirements 6.2, 6.3)

    func testExecutableNameOnlyIsArgumentlessLaunch() {
        XCTAssertTrue(LaunchGuard.isArgumentlessLaunch(["/path/to/yobirin"]))
    }

    func testEmptyArgumentsIsArgumentlessLaunch() {
        XCTAssertTrue(LaunchGuard.isArgumentlessLaunch([]))
    }

    func testWithRequiredOptionsIsNotArgumentlessLaunch() {
        XCTAssertFalse(LaunchGuard.isArgumentlessLaunch(["/path/to/yobirin", "--title", "t", "--message", "m"]))
    }

    func testHelpFlagIsNotArgumentlessLaunch() {
        // --help や不正引数はArgumentParserの領分。ガードは「引数ゼロ」のみを対象とする。
        XCTAssertFalse(LaunchGuard.isArgumentlessLaunch(["/path/to/yobirin", "--help"]))
    }

    // MARK: - No notification is delivered on argumentless launch (Requirement 6.2)

    func testCleanUpAndExitNeverDeliversANotification() {
        let client = MockNotificationCenterClient()
        let expectation = expectation(description: "exit called")

        LaunchGuard.cleanUpAndExit(client: client, exit: { _ in expectation.fulfill() })

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(client.requestAuthorizationCallCount, 0)
        XCTAssertTrue(client.setCategoriesCalls.isEmpty)
        XCTAssertTrue(client.addedRequests.isEmpty)
    }

    // MARK: - Orphaned delivered notifications are swept before exit (Requirement 6.3)

    func testCleanUpAndExitFetchesDeliveredNotifications() {
        let client = MockNotificationCenterClient()
        let expectation = expectation(description: "exit called")

        LaunchGuard.cleanUpAndExit(client: client, exit: { _ in expectation.fulfill() })

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(client.getDeliveredNotificationsCallCount, 1)
    }

    func testCleanUpAndExitRemovesDeliveredNotificationsBeforeExiting() {
        // 掃除完了後にexitすること (fire-and-forgetでexitすると掃除が走る前にプロセスが死ぬ)。
        // exit呼び出し時点でremoveDeliveredNotificationsが既に1回呼ばれていることを確認する
        // (NotificationSessionTests.testHandleTimeoutRemovesDeliveredNotificationBeforeEmittingResult
        // と同じ検証パターン)。
        let client = MockNotificationCenterClient()
        let removeCountAtExitTime = Recorder<Int>(-1)
        let expectation = expectation(description: "exit called")

        LaunchGuard.cleanUpAndExit(
            client: client,
            exit: { _ in
                removeCountAtExitTime.set(client.removeDeliveredCalls.count)
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(removeCountAtExitTime.value, 1)
    }

    func testCleanUpAndExitCallsExitWithCodeZero() {
        let client = MockNotificationCenterClient()
        let exitCodes = Recorder<[Int32]>([])
        let expectation = expectation(description: "exit called")

        LaunchGuard.cleanUpAndExit(
            client: client,
            exit: { code in
                exitCodes.set(exitCodes.value + [code])
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(exitCodes.value, [0])
    }

    // MARK: - Exit must not happen synchronously before the async cleanup completes (Requirement 6.3)

    func testCleanUpAndExitDoesNotExitSynchronouslyBeforeCleanupCompletes() {
        // getDeliveredNotificationsの完了はバックグラウンドスレッドから来る想定 (実UNの挙動)。
        // exitがそのバックグラウンド完了経由でのみ呼ばれ、cleanUpAndExit呼び出しのその場
        // (呼び出し元スレッド上) で同期的に呼ばれていないことを確認する。
        let client = MockNotificationCenterClient()
        let exitCalledFromBackgroundCompletion = Recorder<Bool>(false)
        let expectation = expectation(description: "exit called")

        LaunchGuard.cleanUpAndExit(
            client: client,
            exit: { _ in
                exitCalledFromBackgroundCompletion.set(!Thread.isMainThread)
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(
            exitCalledFromBackgroundCompletion.value,
            "exit must be driven by the async getDeliveredNotifications completion, not called inline synchronously"
        )
    }

    // MARK: - cleanUpAndExit must block the caller until the sweep completes (Requirement 6.3)

    func testCleanUpAndExitBlocksUntilSweepCompletes() {
        // 呼び出し元 (YobirinMain.main()) はcleanUpAndExitがreturnした直後にプロセスをexitさせうる。
        // そのためcleanUpAndExitはexpectation/waitを使わず、呼び出しから戻った時点で
        // 掃除(exit呼び出しとremoveDeliveredNotifications)が既に完了していなければならない。
        let client = MockNotificationCenterClient()
        let exitCalled = Recorder<Bool>(false)

        LaunchGuard.cleanUpAndExit(client: client, exit: { _ in exitCalled.set(true) })

        XCTAssertTrue(exitCalled.value, "cleanUpAndExit must not return before the sweep completed")
        XCTAssertEqual(client.removeDeliveredCalls.count, 1)
    }

    // MARK: - timeout bounds the wait when the sweep never completes (Requirement 6.2)

    func testCleanUpAndExitReturnsAfterTimeoutWhenSweepNeverCompletes() {
        // UN側が稀にハングしても、Requirement 6.2の「即終了」を損なわないよう
        // cleanUpAndExitはtimeoutで上限を超えて待ち続けないこと。
        let client = NeverCompletingNotificationCenterClient()
        let exitCalled = Recorder<Bool>(false)

        LaunchGuard.cleanUpAndExit(client: client, timeout: .milliseconds(50), exit: { _ in exitCalled.set(true) })

        XCTAssertFalse(exitCalled.value, "exit must not be called when the sweep never completes")
    }
}
