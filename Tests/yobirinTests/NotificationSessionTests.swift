import CoreGraphics
import ImageIO
import UserNotifications
import XCTest

@testable import yobirin

/// `NotificationCenterClient` のモック実装。
/// 実センター (`UNUserNotificationCenter.current()`) はバンドル外のswift testでは
/// `bundleProxyForCurrentProcess is nil` で例外死するため、テストはこのモックに対して行う。
private final class MockNotificationCenterClient: NotificationCenterClient {
    private(set) var setCategoriesCalls: [Set<UNNotificationCategory>] = []
    private(set) var removeDeliveredCalls: [[String]] = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var callOrder: [String] = []

    /// `getDeliveredNotificationIdentifiers` が返す識別名列。group置換走査のテストで注入する
    /// (task 2.1。既定は空配列で、従来どおりの挙動を保つ)。
    var deliveredIdentifiersToReturn: [String] = []

    /// true のとき `getDeliveredNotificationIdentifiers` のcompletionHandlerをすぐに呼ばず
    /// `pendingCompletionHandler` に保持する。group置換走査の途中でキャンセルが確定する
    /// レースを再現するため (task 2.2, Requirement 2.5 非同期ガード)。
    var deferCompletionHandler = false
    private var pendingCompletionHandler: (([String]) -> Void)?

    /// 保留していたcompletionHandlerを手動で発火する。
    func firePendingCompletionHandler() {
        let handler = pendingCompletionHandler
        pendingCompletionHandler = nil
        handler?(deliveredIdentifiersToReturn)
    }

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        completionHandler(true, nil)
    }

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

    func getDeliveredNotificationIdentifiers(completionHandler: @escaping ([String]) -> Void) {
        if deferCompletionHandler {
            pendingCompletionHandler = completionHandler
        } else {
            completionHandler(deliveredIdentifiersToReturn)
        }
    }

    /// `doctor` 専用の読み取り窓口 (Requirement 15.4)。このモックを使う経路では呼ばれない。
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {}
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

    private struct PNGFixtureError: Error {}

    /// テスト用の有効なPNGファイルを使い捨ての一時ディレクトリに生成する。
    /// `UNNotificationAttachment` は初期化時にソースファイルを移動させるため
    /// (Requirement 1.4のテストが `assets/icon/*.png` のようなリポジトリ資産を
    /// 消費しないよう)、ここで毎回新規のfixtureを作る。
    private static func makeTemporaryPNGFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let width = 4
        let height = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw PNGFixtureError()
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw PNGFixtureError()
        }

        let url = directory.appendingPathComponent("fixture.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw PNGFixtureError()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PNGFixtureError()
        }
        return url
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

    // MARK: - Group replacement ordering (Requirements 1.1-1.5, 2.1, 2.2)

    func testDeliverWithGroupUsesNewIdentifierSchemeAndOrdersSetCategoriesThenRemoveThenAdd() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let request = makeRequest(group: "build")

        try session.deliver(request)

        // 置換走査の非同期化 (design.md Implementation Notes) により、同期部分の
        // setNotificationCategoriesが一覧取得 → 削除 → add より先に実行される。
        XCTAssertEqual(client.callOrder, ["setNotificationCategories", "removeDeliveredNotifications", "add"])
        let identifier = try XCTUnwrap(client.addedRequests.first?.identifier)
        XCTAssertTrue(identifier.hasPrefix(NotificationIdentity.replacementPrefix(group: "build")))
        XCTAssertNotEqual(identifier, "build", "identifierはもはやgroupそのものではない (research.md DD-1)")
    }

    /// モックが返す識別名列 (自group 2件 + 先頭部分が重なる別group 1件 + groupなし1件) から
    /// 自groupの2件だけが削除されることを固定する (task 2.1, Requirement 1.1, 1.2, 1.4, 1.5)。
    func testDeliverWithGroupRemovesOnlyOwnGroupIdentifiersFromDeliveredList() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let ownGroup = "abc"
        // base64("abc") は base64("abcd") の接頭辞だが、"#" 終端により識別名としては
        // 一致しない (research.md DD-1)。先頭部分が重なる別groupの代表例として使う。
        let overlappingGroup = "abcd"
        let ownPrefix = NotificationIdentity.replacementPrefix(group: ownGroup)
        let own1 = ownPrefix + UUID().uuidString
        let own2 = ownPrefix + UUID().uuidString
        let overlappingIdentifier = NotificationIdentity.makeIdentifier(group: overlappingGroup)
        let noGroupIdentifier = NotificationIdentity.makeIdentifier(group: nil)
        client.deliveredIdentifiersToReturn = [own1, own2, overlappingIdentifier, noGroupIdentifier]
        let request = makeRequest(group: ownGroup)

        try session.deliver(request)

        XCTAssertEqual(client.removeDeliveredCalls, [[own1, own2]])
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

    func testDeliverWithValidImageAttachesOneAttachmentToContent() throws {
        let client = MockNotificationCenterClient()
        let session = NotificationSession(client: client, actions: [], onResult: { _ in })
        let pngURL = try Self.makeTemporaryPNGFile()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pngURL.deletingLastPathComponent())
        }
        let request = makeRequest(image: pngURL.path)

        try session.deliver(request)

        let content = try XCTUnwrap(client.addedRequests.first?.content)
        XCTAssertEqual(content.attachments.count, 1)
        let attachment = try XCTUnwrap(content.attachments.first)
        XCTAssertFalse(attachment.identifier.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path))
    }

    // MARK: - Response classification (Requirements 3.1, 3.2, 3.3, 3.4)

    func testHandleResponseDefaultActionEmitsClicked() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.clicked])
    }

    func testHandleResponseDismissActionEmitsDismissed() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.dismissed])
    }

    func testHandleResponseActionIdentifierEmitsActionWithLabelAndIndex() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: ["Open", "Dismiss"], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "yobirin-action-1", userText: nil)

        XCTAssertEqual(results, [.action(label: "Dismiss", index: 1)])
    }

    func testHandleResponseWithDuplicateLabelsIdentifiesByIndexNotLabel() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: ["Open", "Open"], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "yobirin-action-1", userText: nil)

        XCTAssertEqual(results, [.action(label: "Open", index: 1)])
    }

    func testHandleResponseReplyIdentifierEmitsRepliedWithText() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: NotificationSessionIdentifiers.replyActionIdentifier, userText: "了解です")

        XCTAssertEqual(results, [.replied(text: "了解です")])
    }

    func testHandleResponseUnknownIdentifierDoesNotEmit() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "com.apple.unknown", userText: nil)

        XCTAssertTrue(results.isEmpty)
    }

    func testHandleResponseOutOfRangeActionIndexDoesNotEmit() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: ["Open"], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: "yobirin-action-5", userText: nil)

        XCTAssertTrue(results.isEmpty)
    }

    func testHandleTimeoutEmitsTimeout() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleTimeout()

        XCTAssertEqual(results, [.timeout])
    }

    // MARK: - Exclusive one-shot commitment (Requirement 3.8)

    func testSecondResponseAfterCommitIsIgnored() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
        session.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.clicked])
    }

    func testTimeoutAfterResponseIsIgnored() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil)
        session.handleTimeout()

        XCTAssertEqual(results, [.dismissed])
    }

    func testResponseAfterTimeoutIsIgnored() {
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: MockNotificationCenterClient(), actions: [], onResult: { results.append($0) })

        session.handleTimeout()
        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)

        XCTAssertEqual(results, [.timeout])
    }

    // MARK: - Timeout removes delivered notification before output decision (Requirement 5.2)

    func testHandleTimeoutRemovesDeliveredNotificationBeforeEmittingResult() throws {
        let client = MockNotificationCenterClient()
        var removalCountAtEmitTime = -1
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: client,
            actions: [],
            onResult: { result in
                removalCountAtEmitTime = client.removeDeliveredCalls.count
                results.append(result)
            }
        )
        let request = makeRequest()
        try session.deliver(request)
        let deliveredIdentifier = try XCTUnwrap(client.addedRequests.first?.identifier)

        session.handleTimeout()

        // 削除が先に完了してからemitされること (design.md System Flows のタイムアウト分岐)
        XCTAssertEqual(removalCountAtEmitTime, 1)
        XCTAssertEqual(client.removeDeliveredCalls, [[deliveredIdentifier]])
        XCTAssertEqual(results, [.timeout])
    }

    func testHandleResponseClickedDoesNotRemoveDeliveredNotification() throws {
        let client = MockNotificationCenterClient()
        var results: [NotificationResult] = []
        let session = NotificationSession(client: client, actions: [], onResult: { results.append($0) })
        let request = makeRequest()
        try session.deliver(request)

        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)

        XCTAssertTrue(client.removeDeliveredCalls.isEmpty)
        XCTAssertEqual(results, [.clicked])
    }

    /// セッションAのtimeoutが、モック上のセッションBの識別名を削除しないことを固定する
    /// (task 2.1, 修正対象のバグの回帰テスト。Requirement 1.1, 1.2)。
    func testHandleTimeoutOfOneSessionDoesNotRemoveAnotherSessionsIdentifierOnSharedClient() throws {
        let client = MockNotificationCenterClient()
        let sessionA = NotificationSession(client: client, actions: [], onResult: { _ in })
        let sessionB = NotificationSession(client: client, actions: [], onResult: { _ in })

        try sessionA.deliver(makeRequest(group: "build"))
        let identifierA = try XCTUnwrap(client.addedRequests[0].identifier)
        try sessionB.deliver(makeRequest(group: "build"))
        let identifierB = try XCTUnwrap(client.addedRequests[1].identifier)

        XCTAssertNotEqual(identifierA, identifierB, "同一groupでも識別名は毎回別採番であること")

        sessionA.handleTimeout()

        XCTAssertEqual(client.removeDeliveredCalls.last, [identifierA])
        XCTAssertFalse(
            client.removeDeliveredCalls.flatMap { $0 }.contains(identifierB),
            "セッションAのtimeoutがセッションBの識別名を削除してはならない"
        )
    }

    // MARK: - Cancellation (Requirements 2.1, 2.4, 2.5, 1.1)

    /// SIGTERMによるキャンセル入力。自分の識別名を削除してから `.canceled` で確定する
    /// (design.md System Flows「SIGTERMキャンセル」、既存のtimeoutテストと同じパターン)。
    func testHandleCancelRemovesDeliveredNotificationBeforeEmittingResult() throws {
        let client = MockNotificationCenterClient()
        var removalCountAtEmitTime = -1
        var results: [NotificationResult] = []
        let session = NotificationSession(
            client: client,
            actions: [],
            onResult: { result in
                removalCountAtEmitTime = client.removeDeliveredCalls.count
                results.append(result)
            }
        )
        let request = makeRequest()
        try session.deliver(request)
        let deliveredIdentifier = try XCTUnwrap(client.addedRequests.first?.identifier)

        session.handleCancel()

        XCTAssertEqual(removalCountAtEmitTime, 1)
        XCTAssertEqual(client.removeDeliveredCalls, [[deliveredIdentifier]])
        XCTAssertEqual(results, [.canceled])
    }

    /// 応答で確定済みの場合、後から来る `handleCancel` は既存の一度きり確定機構により無視される
    /// (Requirement 2.4: 先着が勝つ)。
    func testHandleCancelAfterResponseIsIgnored() throws {
        let client = MockNotificationCenterClient()
        var results: [NotificationResult] = []
        let session = NotificationSession(client: client, actions: [], onResult: { results.append($0) })
        let request = makeRequest()
        try session.deliver(request)

        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
        session.handleCancel()

        XCTAssertEqual(results, [.clicked])
        XCTAssertTrue(client.removeDeliveredCalls.isEmpty, "clicked確定は通知を削除しないため、後続のcancelでも削除は増えない")
    }

    /// 配信前にキャンセルが確定した場合、`deliver` の同期部分冒頭のガードにより
    /// category登録・addのいずれも行われない (Requirement 2.5、research.md DD-4)。
    func testDeliverAfterCancelDoesNotAddNotification() throws {
        let client = MockNotificationCenterClient()
        var results: [NotificationResult] = []
        let session = NotificationSession(client: client, actions: [], onResult: { results.append($0) })

        session.handleCancel()
        try session.deliver(makeRequest())

        XCTAssertTrue(client.addedRequests.isEmpty)
        XCTAssertTrue(client.setCategoriesCalls.isEmpty)
        XCTAssertEqual(results, [.canceled])
    }

    /// group置換走査 (非同期completion) の途中でキャンセルが確定した場合、completion内の
    /// `add` 直前のガードにより配信が握り潰される (Requirement 2.5、research.md DD-4)。
    /// これを怠るとレースで孤児通知が出る。
    func testCancelDuringGroupReplacementScanPreventsAdd() throws {
        let client = MockNotificationCenterClient()
        client.deferCompletionHandler = true
        var results: [NotificationResult] = []
        let session = NotificationSession(client: client, actions: [], onResult: { results.append($0) })
        let request = makeRequest(group: "build")

        try session.deliver(request)
        session.handleCancel()
        client.firePendingCompletionHandler()

        XCTAssertTrue(client.addedRequests.isEmpty, "走査完了時点で確定済みならaddを握り潰す")
        XCTAssertEqual(results, [.canceled])
    }

    /// 未配信 (`deliver` 未呼び出し) のキャンセルは、削除なしで `.canceled` として確定する。
    func testHandleCancelWithoutPriorDeliverCommitsWithoutRemoval() {
        let client = MockNotificationCenterClient()
        var results: [NotificationResult] = []
        let session = NotificationSession(client: client, actions: [], onResult: { results.append($0) })

        session.handleCancel()

        XCTAssertTrue(client.removeDeliveredCalls.isEmpty)
        XCTAssertEqual(results, [.canceled])
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

/// `NotificationIdentity` の不変条件テスト (design.md NotificationIdentity, research.md DD-1)。
final class NotificationIdentityTests: XCTestCase {
    /// 符号化結果が接頭辞関係になる組を含む、先頭部分が重なる group の組。
    private static let overlappingGroupPairs: [(String, String)] = [
        ("a", "ab"),
        ("a", "a#b"),
        ("abc", "abcd"),
    ]

    // MARK: - makeIdentifier(group:) は常に自 group の replacementPrefix を接頭辞に持つ (Requirement 1.4, 1.5)

    func testMakeIdentifierWithGroupHasOwnReplacementPrefix() {
        for group in ["build", "a", "ab", "a#b", "abc", "abcd", "日本語", "#"] {
            let identifier = NotificationIdentity.makeIdentifier(group: group)
            let prefix = NotificationIdentity.replacementPrefix(group: group)
            XCTAssertTrue(identifier.hasPrefix(prefix), "group: \(group)")
        }
    }

    func testMakeIdentifierWithoutGroupIsUUIDAlone() {
        let identifier = NotificationIdentity.makeIdentifier(group: nil)
        XCTAssertNotNil(UUID(uuidString: identifier))
    }

    // MARK: - 先頭部分が重なる別 group の接頭辞は互いに一致しない (Requirement 1.4)

    func testReplacementPrefixesOfOverlappingGroupsDoNotMatchEachOther() {
        for (lhs, rhs) in Self.overlappingGroupPairs {
            let lhsPrefix = NotificationIdentity.replacementPrefix(group: lhs)
            let rhsPrefix = NotificationIdentity.replacementPrefix(group: rhs)
            XCTAssertFalse(lhsPrefix.hasPrefix(rhsPrefix), "\(lhs) prefix vs \(rhs) prefix")
            XCTAssertFalse(rhsPrefix.hasPrefix(lhsPrefix), "\(rhs) prefix vs \(lhs) prefix")
        }
    }

    func testReplacementPrefixDoesNotMatchOtherOverlappingGroupIdentifier() {
        for (lhs, rhs) in Self.overlappingGroupPairs {
            let lhsPrefix = NotificationIdentity.replacementPrefix(group: lhs)
            let rhsIdentifier = NotificationIdentity.makeIdentifier(group: rhs)
            XCTAssertFalse(rhsIdentifier.hasPrefix(lhsPrefix), "\(lhs) prefix vs \(rhs) identifier")

            let rhsPrefix = NotificationIdentity.replacementPrefix(group: rhs)
            let lhsIdentifier = NotificationIdentity.makeIdentifier(group: lhs)
            XCTAssertFalse(lhsIdentifier.hasPrefix(rhsPrefix), "\(rhs) prefix vs \(lhs) identifier")
        }
    }

    // MARK: - group なしの識別名はいかなる replacementPrefix にも一致しない (Requirement 1.5)

    func testIdentifierWithoutGroupDoesNotMatchAnyReplacementPrefix() {
        let identifier = NotificationIdentity.makeIdentifier(group: nil)
        for group in ["build", "a", "ab", "a#b", "abc", "abcd", "日本語", "#"] {
            let prefix = NotificationIdentity.replacementPrefix(group: group)
            XCTAssertFalse(identifier.hasPrefix(prefix), "group: \(group)")
        }
    }

    // MARK: - `#` や非ASCIIを含む group の往復 (research.md DD-1)

    func testMakeIdentifierRoundTripsForHashAndNonASCIIGroups() {
        for group in ["a#b", "#", "日本語"] {
            let identifier = NotificationIdentity.makeIdentifier(group: group)
            let prefix = NotificationIdentity.replacementPrefix(group: group)
            XCTAssertTrue(identifier.hasPrefix(prefix), "group: \(group)")
            XCTAssertFalse(identifier.dropFirst(prefix.count).isEmpty, "group: \(group)")
        }
    }
}
