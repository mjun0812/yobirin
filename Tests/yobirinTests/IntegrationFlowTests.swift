import UserNotifications
import XCTest

@testable import yobirin

/// Task 5.1: コンポーネント横断の結合順序を検証する結合テスト。
///
/// `AppFlow` + `NotificationSession` + `ExitCoordinator` を実際に連結し、モック
/// (`NotificationCenterClient` / `Scheduler` / writer / exit) に対して以下を検証する:
/// - group置換の呼び出し順 (Requirement 2.1)
/// - timeout確定時の 削除 → 出力 → 遅延 → 終了 の順序 (Requirements 5.2, 6.1)
/// - 応答とタイマー競合時の一度きり出力 (Requirement 3.8)
/// - deliver失敗時の環境エラー出力とタイマー未開始 (task 3.1レビュー提案の回収)
///
/// 各コンポーネント単位の網羅的な検証は既存の `NotificationSessionTests` /
/// `AppFlowTests` / `ExitCoordinatorTests` に委ねる。ここでは重複を避け、コンポーネントを
/// またいだ結合順序だけを見る。モックはこのファイル内で完結させ (既存テストファイルの
/// 重複private実装と同じパターン)、既存テストの意味には触れない。

/// `NotificationCenterClient` のモック。呼び出し順を `OrderRecorder` へ記録する。
private final class MockNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    let recorder: OrderRecorder
    var pendingAuthorizationCompletion: ((Bool, Error?) -> Void)?
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removeDeliveredCalls: [[String]] = []

    init(recorder: OrderRecorder) {
        self.recorder = recorder
    }

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        pendingAuthorizationCompletion = completionHandler
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        recorder.record("setNotificationCategories")
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removeDeliveredCalls.append(identifiers)
        recorder.record("removeDeliveredNotifications")
    }

    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        recorder.record("add")
        completionHandler?(nil)
    }

    func getDeliveredNotificationIdentifiers(completionHandler: @escaping ([String]) -> Void) {
        completionHandler([])
    }

    /// `doctor` 専用の読み取り窓口 (Requirement 15.4)。このモックを使う経路では呼ばれない。
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {}
}

/// `Scheduler` のモック。手動発火のため実際には発火せず、呼び出しだけを記録する
/// (他のテストファイルのMockSchedulerと同じパターン。ファイルごとにprivateなので複製する)。
private final class MockScheduler {
    private(set) var scheduledCalls: [(seconds: TimeInterval, block: () -> Void)] = []

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        scheduledCalls.append((seconds, block))
        return NoopCancellable()
    }

    func fire(at index: Int) {
        scheduledCalls[index].block()
    }
}

private struct NoopCancellable: Cancellable {
    func cancel() {}
}

/// スレッドセーフな順序記録者。`NotificationCenterClient` / 出力書き込み / exitの各呼び出しを
/// 単一のタイムラインへ記録し、コンポーネントをまたいだ順序をassertできるようにする。
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    func record(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

final class IntegrationFlowTests: XCTestCase {
    private func makeRequest(
        group: String? = nil,
        timeout: Double? = nil,
        image: String? = nil
    ) -> NotificationRequest {
        NotificationRequest(
            title: "t",
            message: "m",
            subtitle: nil,
            group: group,
            timeout: timeout,
            actions: [],
            replyEnabled: false,
            replyPlaceholder: nil,
            sound: nil,
            image: image
        )
    }

    /// `AppFlow` + `NotificationSession` の `onResult` を、design.mdの `AppDelegate` と同じ配線
    /// (実センターへの依存を避けるため `AppDelegate` 自体は使わず、その配線を手動で再現する) で
    /// 結合する。`onOutput` はさらに `ExitCoordinator.finish` へ接続し、書き込み・遅延・exitまで
    /// 一本のチェーンにする。テストが `handleResponse` を直接叩けるよう `NotificationSession` も返す。
    private func makeConnectedChain(
        recorder: OrderRecorder,
        client: MockNotificationCenterClient,
        scheduler: MockScheduler,
        emitted: Recorder<[EmittedOutput]>,
        onResultFailure: (() -> Void)? = nil
    ) -> (flow: AppFlow, session: NotificationSession) {
        let onOutput: (EmittedOutput) -> Void = { output in
            emitted.append(output)
            ExitCoordinator.finish(
                output,
                writer: { destination, text in
                    recorder.record("output:\(destination)")
                    _ = text
                },
                scheduler: scheduler.schedule,
                exit: { _ in recorder.record("exit") }
            )
        }
        let session = NotificationSession(
            client: client,
            actions: [],
            onResult: { result in
                if let onResultFailure {
                    onResultFailure()
                }
                onOutput(ResultEmitter.forResult(ResultOutput(result: result, deliveredAt: nil)))
            }
        )
        let flow = AppFlow(client: client, session: session, scheduler: scheduler.schedule, onOutput: onOutput)
        return (flow, session)
    }

    // MARK: - 1. Full-chain timeout ordering across AppFlow / NotificationSession / ExitCoordinator
    // (Requirements 5.2, 6.1)

    func testFullChainTimeoutConfirmationOrdersDeliverTimerRemoveOutputDelayThenExit() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let (flow, _) = makeConnectedChain(recorder: recorder, client: client, scheduler: scheduler, emitted: emitted)

        flow.start(makeRequest(timeout: 5))
        client.pendingAuthorizationCompletion?(true, nil)

        // 認可成功 → 配信 (setNotificationCategories → add)。タイマーはまだ発火していない。
        XCTAssertEqual(recorder.events, ["setNotificationCategories", "add"])
        XCTAssertEqual(scheduler.scheduledCalls.count, 1, "only the timeout timer should be scheduled so far")

        scheduler.fire(at: 0)  // タイマー発火 → handleTimeout → 削除 → onResult → 出力 → 遅延スケジュール

        XCTAssertEqual(
            scheduler.scheduledCalls.count, 2,
            "the delayed exit must be scheduled next, driven by ExitCoordinator.finish"
        )
        XCTAssertTrue(recorder.events.last == "output:stdout")
        XCTAssertFalse(recorder.events.contains("exit"), "exit must not fire before the delay timer fires")

        scheduler.fire(at: 1)  // 遅延タイマー発火 → exit

        XCTAssertEqual(
            recorder.events,
            ["setNotificationCategories", "add", "removeDeliveredNotifications", "output:stdout", "exit"],
            "コンポーネントをまたいで 配信 → タイマー発火 → 削除 → 出力 → 遅延 → 終了 の順序が守られること"
        )
        XCTAssertEqual(emitted.value.count, 1)
        XCTAssertEqual(emitted.value.first?.destination, .stdout)
        XCTAssertEqual(emitted.value.first?.exitCode, 0)
        XCTAssertEqual(emitted.value.first?.text, "{\"result\":\"timeout\"}")
    }

    // MARK: - 2. Full-chain group replacement ordering (Requirement 2.1)

    func testFullChainWithGroupRemovesExistingBeforeAddingAfterAuthorization() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let (flow, _) = makeConnectedChain(recorder: recorder, client: client, scheduler: scheduler, emitted: emitted)

        flow.start(makeRequest(group: "build"))
        XCTAssertTrue(recorder.events.isEmpty, "no group replacement work should happen before authorization completes")

        client.pendingAuthorizationCompletion?(true, nil)

        // 置換走査の非同期化 (design.md Implementation Notes) により、同期部分の
        // setNotificationCategoriesが一覧取得 → 削除 → add より先に実行される。
        XCTAssertEqual(
            recorder.events,
            ["setNotificationCategories", "removeDeliveredNotifications", "add"],
            "認可 → 配信 (category登録 → 置換走査 → add) の順で、コンポーネントをまたいで守られること"
        )
        XCTAssertEqual(client.removeDeliveredCalls, [[]], "モックの配信済み一覧が空のため削除対象も空")
        let identifier = try XCTUnwrap(client.addedRequests.first?.identifier)
        XCTAssertTrue(identifier.hasPrefix(NotificationIdentity.replacementPrefix(group: "build")))
        XCTAssertNotEqual(identifier, "build", "identifierはもはやgroupそのものではない (research.md DD-1)")
    }

    func testFullChainWithoutGroupNeverRemovesExistingNotifications() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let (flow, _) = makeConnectedChain(recorder: recorder, client: client, scheduler: scheduler, emitted: emitted)

        flow.start(makeRequest(group: nil))
        client.pendingAuthorizationCompletion?(true, nil)

        XCTAssertTrue(client.removeDeliveredCalls.isEmpty)
        XCTAssertEqual(recorder.events, ["setNotificationCategories", "add"])
    }

    // MARK: - 3. Response vs. timer race: exactly one write and one exit regardless of order
    // (Requirement 3.8)

    func testResponseCommittingBeforeTheTimerFiresLaterYieldsExactlyOneWriteAndExit() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let (flow, session) = makeConnectedChain(
            recorder: recorder, client: client, scheduler: scheduler, emitted: emitted)

        flow.start(makeRequest(timeout: 5))
        client.pendingAuthorizationCompletion?(true, nil)

        // 応答が先に確定する
        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
        // 後からタイマーが発火する (競合)
        scheduler.fire(at: 0)
        // 出力確定後にExitCoordinatorがスケジュールした遅延exitを発火させる
        scheduler.fire(at: 1)

        XCTAssertEqual(emitted.value.count, 1, "the response's result must be emitted exactly once")
        XCTAssertEqual(emitted.value.first?.text, "{\"result\":\"clicked\"}")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("output:") }.count, 1)
        XCTAssertEqual(recorder.events.filter { $0 == "exit" }.count, 1)
    }

    func testTimerFiringBeforeALaterResponseYieldsExactlyOneWriteAndExit() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let (flow, session) = makeConnectedChain(
            recorder: recorder, client: client, scheduler: scheduler, emitted: emitted)

        flow.start(makeRequest(timeout: 5))
        client.pendingAuthorizationCompletion?(true, nil)

        // タイマーが先に発火する
        scheduler.fire(at: 0)
        // 後から応答が来る (競合。既に確定済みのため無視されるはず)
        session.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
        // 出力確定後にExitCoordinatorがスケジュールした遅延exitを発火させる
        scheduler.fire(at: 1)

        XCTAssertEqual(emitted.value.count, 1, "the timeout's result must be emitted exactly once")
        XCTAssertEqual(emitted.value.first?.text, "{\"result\":\"timeout\"}")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("output:") }.count, 1)
        XCTAssertEqual(recorder.events.filter { $0 == "exit" }.count, 1)
    }

    // MARK: - 4. deliver failure surfaces as an environment error and never starts the timer
    // (task 3.1 review note)

    func testDeliverFailureEmitsEnvironmentErrorWithoutJSONAndNeverStartsTheTimer() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        var onResultCalled = false
        let (flow, _) = makeConnectedChain(
            recorder: recorder, client: client, scheduler: scheduler, emitted: emitted,
            onResultFailure: { onResultCalled = true }
        )

        // 拡張子なしのパスは `UNNotificationAttachment` がファイルタイプを判別できず
        // 初期化時に投げる (NotificationSessionTests.testDeliverWithUnrecognizedImageTypeThrowsと同じ根拠)。
        flow.start(makeRequest(timeout: 5, image: "/no/such/path/image"))
        client.pendingAuthorizationCompletion?(true, nil)

        XCTAssertEqual(emitted.value.count, 1)
        let output = try XCTUnwrap(emitted.value.first)
        XCTAssertEqual(output.destination, .stderr)
        XCTAssertNotEqual(output.exitCode, 0)
        XCTAssertFalse(
            output.text?.contains("\"result\"") ?? false, "environment errors must never carry a result JSON")
        XCTAssertTrue(client.addedRequests.isEmpty, "delivery must not have gone through")
        // `scheduler` はExitCoordinatorの遅延exitスケジューリングでも使われる共有モックのため、
        // 「未スケジュール」ではなく「timeout秒 (5) のタイマーが1件もない」ことを確認する。
        XCTAssertFalse(
            scheduler.scheduledCalls.contains { $0.seconds == 5 },
            "the timeout timer must not start when delivery fails"
        )
        XCTAssertFalse(onResultCalled, "NotificationSession.onResult must never fire for a delivery failure")
    }
}

/// スレッドセーフな値ボックス (`LaunchGuardTests.Recorder` と同じ発想。ファイルごとにprivateなので複製する)。
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ initialValue: Value) {
        storedValue = initialValue
    }

    func append<Element>(_ element: Element) where Value == [Element] {
        lock.lock()
        storedValue.append(element)
        lock.unlock()
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

// MARK: - 出力方針を通した結合 (Requirements 1, 2, 3: NotifyCommand → onResult → ResultEmitter → ExitCoordinator)

final class OutputPolicyIntegrationTests: XCTestCase {
    /// 実際の通知フローを模し、結果の確定から書き込み・終了コードまでを方針つきで通す。
    private func runFlow(
        result: NotificationResult,
        policy: OutputPolicy
    ) -> (writes: [String], exitCodes: [Int32]) {
        var writes: [String] = []
        var scheduled: [() -> Void] = []
        var exitCodes: [Int32] = []

        let emitted = ResultEmitter.forResult(ResultOutput(result: result, deliveredAt: nil), policy: policy)
        ExitCoordinator.finish(
            emitted,
            writer: { _, text in writes.append(text) },
            scheduler: { _, work in
                scheduled.append(work)
                return FlowNoopCancellable()
            },
            exit: { exitCodes.append($0) }
        )
        for work in scheduled { work() }
        return (writes, exitCodes)
    }

    func testDefaultPolicyWritesJSONAndExitsZero() throws {
        let outcome = runFlow(result: .dismissed, policy: .default)
        XCTAssertEqual(outcome.writes, ["{\"result\":\"dismissed\"}"])
        XCTAssertEqual(outcome.exitCodes, [0])
    }

    func testExitCodePolicyKeepsJSONButChangesTheExitCode() throws {
        let outcome = runFlow(
            result: .dismissed, policy: OutputPolicy(exitCodeEnabled: true, printField: nil))
        XCTAssertEqual(outcome.writes, ["{\"result\":\"dismissed\"}"])
        XCTAssertEqual(outcome.exitCodes, [3])
    }

    func testPrintPolicyWritesTheRawValueOnly() throws {
        let outcome = runFlow(
            result: .replied(text: "next step"),
            policy: OutputPolicy(exitCodeEnabled: false, printField: .text))
        XCTAssertEqual(outcome.writes, ["next step"])
        XCTAssertEqual(outcome.exitCodes, [0])
    }

    func testCombinedPolicyWritesTheValueAndSetsTheExitCode() throws {
        let outcome = runFlow(
            result: .action(label: "Approve", index: 1),
            policy: OutputPolicy(exitCodeEnabled: true, printField: .actionIndex))
        XCTAssertEqual(outcome.writes, ["1"])
        XCTAssertEqual(outcome.exitCodes, [11])
    }

    /// 却下に対する --print text: 何も書かれず、終了コードだけが方針に従う (Requirements 2.4, 3.1)。
    func testMissingFieldWritesNothingButExitsWithTheResultCode() throws {
        let outcome = runFlow(
            result: .dismissed,
            policy: OutputPolicy(exitCodeEnabled: true, printField: .text))
        XCTAssertTrue(outcome.writes.isEmpty)
        XCTAssertEqual(outcome.exitCodes, [3])
    }
}

private struct FlowNoopCancellable: Cancellable {
    func cancel() {}
}

// MARK: - Cancellation full-chain ordering (Task 4.1: Requirements 2.2, 2.3, 3.2, 3.3, 1.6)

/// SIGTERMキャンセルの結合順序を固定する。`NotificationSession` (実物) + `MockNotificationCenterClient`
/// を `onResult` で `ResultEmitter.forResult(policy:)` → `ExitCoordinator.finish` (writer / scheduler /
/// exit をモック) へ連結し、design.md System Flows「SIGTERMキャンセル」の
/// 「キャンセル確定 → 自通知の削除 → 出力 → 遅延exit」の順序を、コンポーネントをまたいで検証する。
/// 個別コンポーネントの網羅的な検証は `NotificationSessionTests` の `handleCancel` 系 /
/// `OutputTests` の `canceled` 出力方針に委ね、ここでは連鎖順序と既存5種の連鎖不変性だけを見る。
final class CancellationIntegrationTests: XCTestCase {
    private func makeRequest(group: String? = nil) -> NotificationRequest {
        NotificationRequest(
            title: "t", message: "m", subtitle: nil, group: group, timeout: nil,
            actions: [], replyEnabled: false, replyPlaceholder: nil, sound: nil, image: nil
        )
    }

    /// `IntegrationFlowTests.makeConnectedChain` と同じ配線 (`private` のため型をまたいで再利用できず、
    /// このファイル内で複製する)。書き込み内容と終了コードも記録できるよう `writes` / `exitCodes` を
    /// 追加し、`actions` と `policy` を差し替え可能にする。
    private func makeCancellationChain(
        recorder: OrderRecorder,
        client: MockNotificationCenterClient,
        scheduler: MockScheduler,
        emitted: Recorder<[EmittedOutput]>,
        writes: Recorder<[String]>,
        exitCodes: Recorder<[Int32]>,
        actions: [String] = [],
        policy: OutputPolicy = .default
    ) -> (flow: AppFlow, session: NotificationSession) {
        let onOutput: (EmittedOutput) -> Void = { output in
            emitted.append(output)
            ExitCoordinator.finish(
                output,
                writer: { destination, text in
                    recorder.record("output:\(destination)")
                    writes.append(text)
                },
                scheduler: scheduler.schedule,
                exit: { code in
                    recorder.record("exit")
                    exitCodes.append(code)
                }
            )
        }
        let session = NotificationSession(
            client: client,
            actions: actions,
            onResult: { result in
                onOutput(ResultEmitter.forResult(ResultOutput(result: result, deliveredAt: nil), policy: policy))
            }
        )
        let flow = AppFlow(client: client, session: session, scheduler: scheduler.schedule, onOutput: onOutput)
        return (flow, session)
    }

    // MARK: - 1. Order: cancel confirmation -> own-identifier removal -> output write -> delayed exit
    // (Requirements 2.2, 2.3, 1.6)

    func testFullChainCancelOrdersOwnIdentifierRemovalThenOutputThenDelayedExit() throws {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let writes = Recorder<[String]>([])
        let exitCodes = Recorder<[Int32]>([])
        let (flow, session) = makeCancellationChain(
            recorder: recorder, client: client, scheduler: scheduler,
            emitted: emitted, writes: writes, exitCodes: exitCodes)

        flow.start(makeRequest(group: "cancel-order"))
        client.pendingAuthorizationCompletion?(true, nil)

        // 配信 (category登録 → group置換走査 → add) が完了した時点までのイベント数を基準にする。
        XCTAssertEqual(recorder.events, ["setNotificationCategories", "removeDeliveredNotifications", "add"])
        let deliveredEventCount = recorder.events.count
        let deliveredIdentifier = try XCTUnwrap(client.addedRequests.first?.identifier)

        session.handleCancel()

        // キャンセル確定 → 自分のidentifierの削除 → 出力書き込み、の順で新規イベントが積まれる。
        // 遅延exitタイマーはまだ発火していないためexitはまだ記録されない。
        let eventsAfterCancel = Array(recorder.events.dropFirst(deliveredEventCount))
        XCTAssertEqual(
            eventsAfterCancel, ["removeDeliveredNotifications", "output:stdout"],
            "design.md SIGTERMキャンセルのフロー通り、削除 → 出力の順で記録されること")
        XCTAssertEqual(
            client.removeDeliveredCalls.last, [deliveredIdentifier],
            "削除対象は自分が配信したidentifierのみであること (group置換走査の削除と取り違えないこと)")
        XCTAssertFalse(recorder.events.contains("exit"), "遅延exitが発火するまでexitは呼ばれない")
        XCTAssertEqual(writes.value, ["{\"result\":\"canceled\"}"])

        scheduler.fire(at: scheduler.scheduledCalls.count - 1)  // 遅延exitタイマーを発火

        XCTAssertEqual(recorder.events.last, "exit", "出力の後にexitが続くこと")
        XCTAssertEqual(exitCodes.value, [0], "--exit-code未指定時はcanceledでもexit 0")
    }

    // MARK: - 2. --exit-code and canceled (Requirements 3.2, 3.3)

    func testCancelExitCodeIsFiveWhenExitCodeEnabled() throws {
        let result = runCancelFlow(policy: OutputPolicy(exitCodeEnabled: true, printField: nil))
        XCTAssertEqual(result.exitCodes, [ResultEmitter.canceledExitCode])
        XCTAssertEqual(result.exitCodes, [5])
    }

    func testCancelExitCodeIsZeroWithoutExitCodeFlag() throws {
        let result = runCancelFlow(policy: .default)
        XCTAssertEqual(result.exitCodes, [0])
    }

    // MARK: - 3. --print result / --print text and canceled (Requirement 2.2 「既存の結果出力と同じ経路」)

    func testCancelPrintResultWritesTheRawCanceledValue() throws {
        let result = runCancelFlow(policy: OutputPolicy(exitCodeEnabled: false, printField: .result))
        XCTAssertEqual(result.writes, ["canceled"])
    }

    func testCancelPrintTextWritesNothing() throws {
        let result = runCancelFlow(policy: OutputPolicy(exitCodeEnabled: true, printField: .text))
        XCTAssertTrue(result.writes.isEmpty, "canceledにtextフィールドは存在しないため書き込みが発生しないこと")
        XCTAssertEqual(result.exitCodes, [5], "書き込みがなくても終了コードは結果に対応すること (Requirement 2.4系の踏襲)")
    }

    /// `policy` を差し替えてキャンセルを結合チェーンで1回流し、書き込み内容と終了コードを返す。
    private func runCancelFlow(policy: OutputPolicy) -> (writes: [String], exitCodes: [Int32]) {
        let recorder = OrderRecorder()
        let client = MockNotificationCenterClient(recorder: recorder)
        let scheduler = MockScheduler()
        let emitted = Recorder<[EmittedOutput]>([])
        let writes = Recorder<[String]>([])
        let exitCodes = Recorder<[Int32]>([])
        let (flow, session) = makeCancellationChain(
            recorder: recorder, client: client, scheduler: scheduler,
            emitted: emitted, writes: writes, exitCodes: exitCodes, policy: policy)

        flow.start(makeRequest())
        client.pendingAuthorizationCompletion?(true, nil)
        session.handleCancel()
        scheduler.fire(at: scheduler.scheduledCalls.count - 1)

        return (writes.value, exitCodes.value)
    }

    // MARK: - 4. Existing 5 result kinds remain unchanged through the same connected chain
    // (Requirement 1.6, 3.6 の結合チェーン版)

    func testFullChainAllSixResultKindsProduceUnchangedJSONAndExitCode() throws {
        let cases:
            [(name: String, actions: [String], trigger: (NotificationSession) -> Void, json: String, exitCode: Int32)] =
                [
                    (
                        "clicked", [],
                        { $0.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil) },
                        "{\"result\":\"clicked\"}", 0
                    ),
                    (
                        "action", ["Approve"],
                        {
                            $0.handleResponse(
                                actionIdentifier: NotificationSessionIdentifiers.actionIdentifier(forIndex: 0),
                                userText: nil)
                        },
                        "{\"result\":\"action\",\"action\":\"Approve\",\"actionIndex\":0}", 10
                    ),
                    (
                        "replied", [],
                        {
                            $0.handleResponse(
                                actionIdentifier: NotificationSessionIdentifiers.replyActionIdentifier, userText: "hi")
                        },
                        "{\"result\":\"replied\",\"text\":\"hi\"}", 0
                    ),
                    (
                        "dismissed", [],
                        { $0.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil) },
                        "{\"result\":\"dismissed\"}", 3
                    ),
                    ("timeout", [], { $0.handleTimeout() }, "{\"result\":\"timeout\"}", 4),
                    ("canceled", [], { $0.handleCancel() }, "{\"result\":\"canceled\"}", 5),
                ]

        for testCase in cases {
            let recorder = OrderRecorder()
            let client = MockNotificationCenterClient(recorder: recorder)
            let scheduler = MockScheduler()
            let emitted = Recorder<[EmittedOutput]>([])
            let writes = Recorder<[String]>([])
            let exitCodes = Recorder<[Int32]>([])
            let (flow, session) = makeCancellationChain(
                recorder: recorder, client: client, scheduler: scheduler,
                emitted: emitted, writes: writes, exitCodes: exitCodes, actions: testCase.actions,
                policy: OutputPolicy(exitCodeEnabled: true, printField: nil))

            flow.start(makeRequest())
            client.pendingAuthorizationCompletion?(true, nil)
            testCase.trigger(session)
            scheduler.fire(at: scheduler.scheduledCalls.count - 1)

            XCTAssertEqual(writes.value, [testCase.json], "\(testCase.name): 結合チェーンでのJSON出力が不変であること")
            XCTAssertEqual(exitCodes.value, [testCase.exitCode], "\(testCase.name): 結合チェーンでの終了コードが不変であること")
        }
    }
}
