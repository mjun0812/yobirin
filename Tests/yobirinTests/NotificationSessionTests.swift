import XCTest
import UserNotifications

@testable import yobirin

/// `NotificationCenterClient` のモック実装。
/// 実センター (`UNUserNotificationCenter.current()`) はバンドル外のswift testでは
/// `bundleProxyForCurrentProcess is nil` で例外死するため、テストはこのモックに対して行う。
private final class MockNotificationCenterClient: NotificationCenterClient {
    private(set) var setCategoriesCalls: [Set<UNNotificationCategory>] = []
    private(set) var removeDeliveredCalls: [[String]] = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var callOrder: [String] = []

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        setCategoriesCalls.append(categories)
        callOrder.append("setNotificationCategories")
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removeDeliveredCalls.append(identifiers)
        callOrder.append("removeDeliveredNotifications")
    }

    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        callOrder.append("add")
        completionHandler?(nil)
    }

    func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void) {
        completionHandler([])
    }
}

final class NotificationSessionTests: XCTestCase {
    private func makeRequest(
        title: String = "t",
        message: String = "m",
        subtitle: String? = nil,
        group: String? = nil,
        actions: [String] = [],
        replyEnabled: Bool = false,
        replyPlaceholder: String? = nil,
        sound: String? = nil,
        image: String? = nil
    ) -> NotificationRequest {
        NotificationRequest(
            title: title,
            message: message,
            subtitle: subtitle,
            group: group,
            timeout: nil,
            actions: actions,
            replyEnabled: replyEnabled,
            replyPlaceholder: replyPlaceholder,
            sound: sound,
            image: image
        )
    }

    // MARK: - Category registration (design.md NotificationSession / Requirements 4.1, 4.2, 4.3, 4.4)

    func testDeliverRegistersCategoryWithCustomDismissActionEveryCall() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest()

        try session.deliver(request)
        try session.deliver(request)

        XCTAssertEqual(client.setCategoriesCalls.count, 2)
        let category = try XCTUnwrap(client.setCategoriesCalls.first?.first)
        XCTAssertTrue(category.options.contains(.customDismissAction))
    }

    func testDeliverRegistersActionsWithIndexBasedIdentifiers() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: ["Open", "Dismiss"], onResult: { _ in })
        let request = makeRequest(actions: ["Open", "Dismiss"])

        try session.deliver(request)

        let category = try XCTUnwrap(client.setCategoriesCalls.first?.first)
        XCTAssertEqual(category.actions.map(\.identifier), ["yobirin-action-0", "yobirin-action-1"])
        XCTAssertEqual(category.actions.map(\.title), ["Open", "Dismiss"])
    }

    func testDeliverRegistersReplyAsTextInputActionWithPlaceholder() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest(replyEnabled: true, replyPlaceholder: "返信を入力")

        try session.deliver(request)

        let category = try XCTUnwrap(client.setCategoriesCalls.first?.first)
        let replyAction = try XCTUnwrap(category.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(replyAction.textInputPlaceholder, "返信を入力")
    }

    // MARK: - Group replacement ordering (Requirements 2.1, 2.2)

    func testDeliverWithGroupRemovesExistingBeforeAddingUsingGroupAsIdentifier() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest(group: "build")

        try session.deliver(request)

        XCTAssertEqual(client.removeDeliveredCalls, [["build"]])
        XCTAssertEqual(client.callOrder, ["removeDeliveredNotifications", "setNotificationCategories", "add"])
        XCTAssertEqual(client.addedRequests.first?.identifier, "build")
    }

    func testDeliverWithoutGroupDoesNotRemoveExisting() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest(group: nil)

        try session.deliver(request)

        XCTAssertTrue(client.removeDeliveredCalls.isEmpty)
        XCTAssertNotNil(client.addedRequests.first?.identifier)
    }

    // MARK: - Content fields (Requirements 1.1-1.4)

    func testDeliverBuildsContentWithTitleBodySubtitleAndSound() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest(title: "Hello", message: "World", subtitle: "Sub", sound: "default")

        try session.deliver(request)

        let content = try XCTUnwrap(client.addedRequests.first?.content)
        XCTAssertEqual(content.title, "Hello")
        XCTAssertEqual(content.body, "World")
        XCTAssertEqual(content.subtitle, "Sub")
        XCTAssertNotNil(content.sound)
    }

    func testDeliverWithUnrecognizedImageTypeThrows() throws {
        // 拡張子なしのパスは `UNNotificationAttachment` がファイルタイプを判別できず
        // `UNErrorDomain Code=101` で投げる (実測確認済み)。存在しないファイルでも
        // `.png` 等の既知拡張子なら初期化時点では例外にならないため、拡張子を外して検証する。
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest(image: "/no/such/path/image")

        XCTAssertThrowsError(try session.deliver(request))
    }

    // MARK: - Response classification (Requirements 3.1, 3.2, 3.3, 3.4)

    func testHandleResponseDefaultActionEmitsClicked() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.clicked])
    }

    func testHandleResponseDismissActionEmitsDismissed() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.dismissed])
    }

    func testHandleResponseActionIdentifierEmitsActionWithLabelAndIndex() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: ["Open", "Dismiss"], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "yobirin-action-1", userText: nil)

        XCTAssertEqual(results, [.action(label: "Dismiss", index: 1)])
    }

    func testHandleResponseReplyIdentifierEmitsRepliedWithText() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: NotificationSessionIdentifiers.replyActionIdentifier, userText: "了解です")

        XCTAssertEqual(results, [.replied(text: "了解です")])
    }

    func testHandleResponseUnknownIdentifierDoesNotEmit() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "com.apple.unknown", userText: nil)

        XCTAssertTrue(results.isEmpty)
    }

    func testHandleResponseOutOfRangeActionIndexDoesNotEmit() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: ["Open"], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "yobirin-action-5", userText: nil)

        XCTAssertTrue(results.isEmpty)
    }

    func testHandleTimeoutEmitsTimeout() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleTimeout()

        XCTAssertEqual(results, [.timeout])
    }

    // MARK: - Exclusive one-shot commitment (Requirement 3.8)

    func testSecondResponseAfterCommitIsIgnored() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
        session.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.clicked])
    }

    func testTimeoutAfterResponseIsIgnored() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil)
        session.handleTimeout()

        XCTAssertEqual(results, [.dismissed])
    }

    func testResponseAfterTimeoutIsIgnored() {
        var results: [NotificationResult] = []
        let session = NotificationSession(client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleTimeout()
        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.timeout])
    }

    func testConcurrentResponsesCommitExactlyOnce() {
        let counterLock = NSLock()
        var callCount = 0
        let session = NotificationSession(
            client: MockNotificationCenterClient(),
            actions: [],
            onResult: { _ in
                counterLock.lock()
                callCount += 1
                counterLock.unlock()
            }
        )

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index % 2 == 0 {
                session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
            } else {
                session.handleTimeout()
            }
        }

        XCTAssertEqual(callCount, 1)
    }
}
