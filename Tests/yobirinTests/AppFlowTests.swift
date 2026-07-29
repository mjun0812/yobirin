import UserNotifications
import XCTest

@testable import yobirin

/// `NotificationCenterClient` のモック。認可コールバックを即時発火せず保持し、
/// テストから手動で発火できるようにする (Requirement 5.4: 認可コールバック後にのみ配信・タイマーが動くことの検証用)。
private final class MockNotificationCenterClient: NotificationCenterClient {
    private(set) var requestAuthorizationCallCount = 0
    var pendingAuthorizationCompletion: ((Bool, Error?) -> Void)?
    private(set) var setCategoriesCalls: [Set<UNNotificationCategory>] = []
    private(set) var removeDeliveredCalls: [[String]] = []
    private(set) var addedRequests: [UNNotificationRequest] = []

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        requestAuthorizationCallCount += 1
        pendingAuthorizationCompletion = completionHandler
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

    func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void) {
        completionHandler([])
    }

    /// `doctor` 専用の読み取り窓口 (Requirement 15.4)。このモックを使う経路では呼ばれない。
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {}
}

/// `Scheduler` のモック。手動発火のため実際には発火せず、呼び出しだけを記録する。
private final class MockScheduler {
    private(set) var scheduledCalls: [(seconds: TimeInterval, block: () -> Void)] = []

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        scheduledCalls.append((seconds, block))
        return NoopCancellable()
    }

    func fireLast() {
        scheduledCalls.last?.block()
    }
}

private struct NoopCancellable: Cancellable {
    func cancel() {}
}

final class AppFlowTests: XCTestCase {
    private func makeRequest(timeout: Double? = nil) -> NotificationRequest {
        NotificationRequest(
            title: "t",
            message: "m",
            subtitle: nil,
            group: nil,
            timeout: timeout,
            actions: [],
            replyEnabled: false,
            replyPlaceholder: nil,
            sound: nil,
            image: nil
        )
    }

    // MARK: - Authorization is requested on start, before anything else (Requirements 5.4, 7.1)

    func testStartRequestsAuthorization() {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let flow = AppFlow(client: client, session: session, scheduler: scheduler.schedule, onOutput: { _ in })

        flow.start(makeRequest())

        XCTAssertEqual(client.requestAuthorizationCallCount, 1)
    }

    func testDeliveryAndTimerDoNotStartBeforeAuthorizationCompletes() {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let flow = AppFlow(client: client, session: session, scheduler: scheduler.schedule, onOutput: { _ in })

        flow.start(makeRequest(timeout: 5))

        XCTAssertTrue(client.addedRequests.isEmpty)
        XCTAssertTrue(scheduler.scheduledCalls.isEmpty)
    }

    // MARK: - Granted path delivers, and schedules the timer only after authorization (5.1, 5.3, 5.4)

    func testGrantedAfterAuthorizationDeliversNotificationAndSchedulesTimeoutTimer() throws {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let flow = AppFlow(client: client, session: session, scheduler: scheduler.schedule, onOutput: { _ in })

        flow.start(makeRequest(timeout: 5))
        client.pendingAuthorizationCompletion?(true, nil)

        XCTAssertEqual(client.addedRequests.count, 1)
        XCTAssertEqual(scheduler.scheduledCalls.count, 1)
        XCTAssertEqual(scheduler.scheduledCalls.first?.seconds, 5)
    }

    func testGrantedWithoutTimeoutDeliversNotificationButDoesNotScheduleTimer() throws {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let flow = AppFlow(client: client, session: session, scheduler: scheduler.schedule, onOutput: { _ in })

        flow.start(makeRequest(timeout: nil))
        client.pendingAuthorizationCompletion?(true, nil)

        XCTAssertEqual(client.addedRequests.count, 1)
        XCTAssertTrue(scheduler.scheduledCalls.isEmpty)
    }

    // MARK: - Denied paths: both the error branch and granted==false emit exit 2 + stderr without JSON (Requirement 7.2)

    func testAuthorizationErrorEmitsPermissionDeniedExitCode2WithoutJSON() {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        var emitted: [EmittedOutput] = []
        let flow = AppFlow(
            client: client, session: session, scheduler: scheduler.schedule, onOutput: { emitted.append($0) })

        flow.start(makeRequest())
        client.pendingAuthorizationCompletion?(false, NSError(domain: "UNErrorDomain", code: 1))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.destination, .stderr)
        XCTAssertEqual(emitted.first?.exitCode, 2)
        XCTAssertFalse(emitted.first?.text.contains("\"result\"") ?? true)
        XCTAssertTrue(client.addedRequests.isEmpty)
        XCTAssertTrue(scheduler.scheduledCalls.isEmpty)
    }

    func testAuthorizationGrantedFalseWithoutErrorEmitsPermissionDeniedExitCode2WithoutJSON() {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        var emitted: [EmittedOutput] = []
        let flow = AppFlow(
            client: client, session: session, scheduler: scheduler.schedule, onOutput: { emitted.append($0) })

        flow.start(makeRequest())
        client.pendingAuthorizationCompletion?(false, nil)

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.destination, .stderr)
        XCTAssertEqual(emitted.first?.exitCode, 2)
        XCTAssertFalse(emitted.first?.text.contains("\"result\"") ?? true)
        XCTAssertTrue(client.addedRequests.isEmpty)
    }

    // MARK: - Timeout confirmation removes the delivered notification before the output decision (Requirement 5.2)

    func testTimeoutFiringRemovesDeliveredNotificationThenEmitsTimeoutResult() throws {
        let client = MockNotificationCenterClient()
        let scheduler = MockScheduler()
        var emitted: [EmittedOutput] = []
        let session = NotificationSession(
            client: client,
            actions: [],
            onResult: { result in
                emitted.append(ResultEmitter.forResult(ResultOutput(result: result, deliveredAt: nil)))
            }
        )
        let flow = AppFlow(
            client: client, session: session, scheduler: scheduler.schedule, onOutput: { emitted.append($0) })

        flow.start(makeRequest(timeout: 5))
        client.pendingAuthorizationCompletion?(true, nil)
        let deliveredIdentifier = try XCTUnwrap(client.addedRequests.first?.identifier)

        scheduler.fireLast()

        XCTAssertEqual(client.removeDeliveredCalls, [[deliveredIdentifier]])
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.destination, .stdout)
        XCTAssertEqual(emitted.first?.exitCode, 0)
        XCTAssertEqual(emitted.first?.text, "{\"result\":\"timeout\"}")
    }
}
