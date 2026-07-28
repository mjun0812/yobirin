import Foundation
import XCTest

@testable import yobirin

/// `Scheduler` のモック。手動発火のため実際には発火せず、呼び出しだけを記録する
/// (AppFlowTests.swiftのMockSchedulerと同じパターン。ファイルごとにprivateなので複製する)。
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

final class ExitCoordinatorTests: XCTestCase {
    // MARK: - Order: write happens immediately, exit only after the delay fires (Requirement 6.1)

    func testFinishWritesOutputImmediatelyWithoutWaitingForDelay() {
        let scheduler = MockScheduler()
        var writes: [(OutputDestination, String)] = []
        var exitCodes: [Int32] = []

        let output = EmittedOutput(destination: .stdout, text: "{\"result\":\"clicked\"}", exitCode: 0)
        ExitCoordinator.finish(
            output,
            writer: { destination, text in writes.append((destination, text)) },
            scheduler: scheduler.schedule,
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, .stdout)
        XCTAssertEqual(writes.first?.1, "{\"result\":\"clicked\"}")
        XCTAssertTrue(exitCodes.isEmpty, "exit must not fire before the scheduled delay does")
    }

    func testFinishSchedulesExitAfterOneSecondDelay() {
        let scheduler = MockScheduler()
        var exitCodes: [Int32] = []

        let output = EmittedOutput(destination: .stdout, text: "x", exitCode: 0)
        ExitCoordinator.finish(
            output, writer: { _, _ in }, scheduler: scheduler.schedule, exit: { exitCodes.append($0) })

        XCTAssertEqual(scheduler.scheduledCalls.count, 1)
        XCTAssertEqual(scheduler.scheduledCalls.first?.seconds, 1.0)
        XCTAssertTrue(exitCodes.isEmpty)

        scheduler.fireLast()

        XCTAssertEqual(exitCodes, [0])
    }

    func testFinishPassesThroughExitCodeFromEmittedOutput() {
        let scheduler = MockScheduler()
        var exitCodes: [Int32] = []

        let output = EmittedOutput(destination: .stderr, text: "denied", exitCode: 2)
        ExitCoordinator.finish(
            output, writer: { _, _ in }, scheduler: scheduler.schedule, exit: { exitCodes.append($0) })
        scheduler.fireLast()

        XCTAssertEqual(exitCodes, [2])
    }

    func testFinishWritesToStderrDestinationGivenByEmittedOutput() {
        let scheduler = MockScheduler()
        var writes: [(OutputDestination, String)] = []

        let output = EmittedOutput(destination: .stderr, text: "通知が許可されていません", exitCode: 2)
        ExitCoordinator.finish(
            output, writer: { destination, text in writes.append((destination, text)) }, scheduler: scheduler.schedule,
            exit: { _ in })

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, .stderr)
        XCTAssertEqual(writes.first?.1, "通知が許可されていません")
    }

    // MARK: - No re-emission: ExitCoordinator itself must not write again when the delayed exit fires
    // (実装ノート: 「結果確定後にexitまでの遅延中に来た応答が二重出力を起こさない」ための設計制約)

    func testFinishDoesNotWriteAgainWhenTheScheduledExitFires() {
        let scheduler = MockScheduler()
        var writeCount = 0

        let output = EmittedOutput(destination: .stdout, text: "x", exitCode: 0)
        ExitCoordinator.finish(
            output, writer: { _, _ in writeCount += 1 }, scheduler: scheduler.schedule, exit: { _ in })
        scheduler.fireLast()

        XCTAssertEqual(writeCount, 1)
    }

    // MARK: - Flush: 結果はプロセス終了 (遅延exit) を待たずパイプの消費者へ到達する (Requirement 18.1)

    func testDefaultWriterFlushesStdoutSoAPipeConsumerReceivesTheResultImmediately() {
        // fd 1をパイプへ差し替えると、stdioはフルバッファになる (ttyの行バッファと異なる)。
        // flushしない実装では書き込みがバッファに滞留し、ここでの非ブロッキングreadで何も読めない。
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        fflush(stdout)
        let savedStdout = dup(STDOUT_FILENO)
        dup2(fds[1], STDOUT_FILENO)

        ExitCoordinator.defaultWriter(.stdout, "{\"result\":\"clicked\"}")

        let flags = fcntl(fds[0], F_GETFL)
        _ = fcntl(fds[0], F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fds[0], &buffer, buffer.count)

        // アサート前にfd 1を復元する (失敗メッセージがパイプへ吸われないように)
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        close(fds[0])
        close(fds[1])

        XCTAssertGreaterThan(count, 0, "the result must be readable from the pipe before process exit")
        let received = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
        XCTAssertEqual(received, "{\"result\":\"clicked\"}\n")
    }
}
