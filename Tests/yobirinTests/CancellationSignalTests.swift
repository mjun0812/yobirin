import Darwin
import Dispatch
import XCTest

@testable import yobirin

/// `CancellationSignal` の配線を検証する (design.md CancellationSignal、Requirements 2.5, 2.6, 2.7)。
///
/// - Important: `signal(SIGTERM, SIG_IGN)` はプロセス全体の既定動作を書き換える。テスト実行後も
///   SIGTERM の既定動作は元に戻らないが、xctestプロセス自身へ送るだけなので他プロセスへの影響は
///   なく、SIGTERM を使う既存テストも他にない (リポジトリ内を grep 済み)。
final class CancellationSignalTests: XCTestCase {
    /// テスト専用キューへ登録し、`kill(getpid(), SIGTERM)` で注入したコールバックが呼ばれること
    /// を確認する。runloop への依存を避けるため main queue は使わない。
    func testInstallInvokesOnCancelWhenProcessReceivesSIGTERM() {
        let queue = DispatchQueue(label: "CancellationSignalTests.testInstallInvokesOnCancelWhenProcessReceivesSIGTERM")
        let expectation = expectation(description: "onCancel invoked")

        let source = CancellationSignal.install(queue: queue) {
            expectation.fulfill()
        }

        kill(getpid(), SIGTERM)

        wait(for: [expectation], timeout: 5)
        withExtendedLifetime(source) {}
    }

    /// 契約の検証: 複数回 SIGTERM を送っても1回目の発火で確認が取れる (少なくとも1回発火する)。
    func testInstallInvokesOnCancelRepeatedlyAcrossMultipleSignals() {
        let queue = DispatchQueue(label: "CancellationSignalTests.testInstallInvokesOnCancelRepeatedly")
        let firstExpectation = expectation(description: "first onCancel invoked")
        let secondExpectation = expectation(description: "second onCancel invoked")
        var callCount = 0

        let source = CancellationSignal.install(queue: queue) {
            callCount += 1
            if callCount == 1 {
                firstExpectation.fulfill()
            } else if callCount == 2 {
                secondExpectation.fulfill()
            }
        }

        kill(getpid(), SIGTERM)
        wait(for: [firstExpectation], timeout: 5)

        kill(getpid(), SIGTERM)
        wait(for: [secondExpectation], timeout: 5)

        withExtendedLifetime(source) {}
    }
}
