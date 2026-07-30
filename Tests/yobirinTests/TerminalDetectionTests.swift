import XCTest

@testable import yobirin

final class TerminalDetectionTests: XCTestCase {
    // MARK: - 標準ストリームの端末接続判定 (Requirements 12.1, 12.2)

    func testReturnsFalseWhenNoStandardStreamIsTerminal() throws {
        XCTAssertFalse(TerminalDetection.isAnyStandardStreamTerminal { _ in false })
    }

    func testReturnsTrueWhenOnlyStandardInputIsTerminal() throws {
        XCTAssertTrue(TerminalDetection.isAnyStandardStreamTerminal { $0 == STDIN_FILENO })
    }

    func testReturnsTrueWhenOnlyStandardOutputIsTerminal() throws {
        XCTAssertTrue(TerminalDetection.isAnyStandardStreamTerminal { $0 == STDOUT_FILENO })
    }

    /// 標準出力をリダイレクトしても標準エラーが端末なら対話とみなす (design.md DD-5)。
    func testReturnsTrueWhenOnlyStandardErrorIsTerminal() throws {
        XCTAssertTrue(TerminalDetection.isAnyStandardStreamTerminal { $0 == STDERR_FILENO })
    }

    func testReturnsTrueWhenAllStandardStreamsAreTerminals() throws {
        XCTAssertTrue(TerminalDetection.isAnyStandardStreamTerminal { _ in true })
    }

    /// 判定対象を標準ストリーム3本に限定する。他のディスクリプタを見ないことを保証する。
    func testInspectsOnlyStandardDescriptors() throws {
        var inspected: [Int32] = []
        _ = TerminalDetection.isAnyStandardStreamTerminal { descriptor in
            inspected.append(descriptor)
            return false
        }
        XCTAssertEqual(Set(inspected), [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO])
    }
}
