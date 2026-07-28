import Foundation
import XCTest

@testable import yobirin

/// `.execInstalledBundle` 決定時の実引き継ぎ (design.md 透過ディスパッチの詳細、
/// Requirements 17.1, 17.2, 17.4, 17.5, 17.7)。
///
/// exec・stderrWriter・exitをすべて注入し、実プロセスを起動せずに配線ロジックのみを検証する
/// (実プロセスでの引数透過・バージョン案内の確認は `ProcessLaunchIntegrationTests` が担う)。
final class BundleHandoffTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-bundle-handoff-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    /// `<tempRoot>/Yobirin.app` を偽バンドルとして組み立てる (Info.plistのみ)。
    private func makeFakeBundle(version: String) -> ProfileNaming {
        let naming = ProfileNaming.default(homeDirectory: tempRoot.path)
        let contentsDir = URL(fileURLWithPath: naming.bundlePath).appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version]
        let data = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try! data.write(to: contentsDir.appendingPathComponent("Info.plist"))
        return naming
    }

    // MARK: - argv[0]差し替えと引数透過 (Requirement 17.1, 17.2)

    func testExecCalledWithMachOPathAsArgv0AndArgumentsPassthroughIncludingProfile() {
        let naming = makeFakeBundle(version: "1.0.0")
        var execCalls: [(String, [String])] = []

        BundleHandoff.execDefaultBundle(
            naming: naming,
            arguments: ["/old/yobirin", "--title", "t", "--profile", "claude", "--message", "m"],
            currentVersion: "1.0.0",
            stderrWriter: { _ in },
            exit: { _ in },
            exec: { path, args in execCalls.append((path, args)) }
        )

        XCTAssertEqual(execCalls.count, 1)
        XCTAssertEqual(execCalls.first?.0, naming.machOPath)
        // --profile はここでは除去されない (バンドル内NotifyCommandが二段目のディスパッチで処理する)。
        XCTAssertEqual(
            execCalls.first?.1,
            [naming.machOPath, "--title", "t", "--profile", "claude", "--message", "m"]
        )
    }

    // MARK: - バージョン比較 (Requirement 17.4)

    func testNoUpdateNoticeWhenVersionsMatch() {
        let naming = makeFakeBundle(version: "1.0.0")
        var stderrMessages: [String] = []

        BundleHandoff.execDefaultBundle(
            naming: naming,
            arguments: ["/old/yobirin"],
            currentVersion: "1.0.0",
            stderrWriter: { stderrMessages.append($0) },
            exit: { _ in },
            exec: { _, _ in }
        )

        // execがreturnした (フェイクは常にreturnする) ため後続の失敗メッセージは書かれるが、
        // バージョン一致の更新案内 ("yobirin install" を含む文言) は含まれない。
        XCTAssertEqual(stderrMessages.count, 1)
        XCTAssertFalse(stderrMessages[0].contains("run 'yobirin install'"))
    }

    func testUpdateNoticeWrittenToStderrBeforeExecWhenVersionsMismatch() {
        let naming = makeFakeBundle(version: "0.9.0")
        var events: [String] = []

        BundleHandoff.execDefaultBundle(
            naming: naming,
            arguments: ["/old/yobirin"],
            currentVersion: "1.0.0",
            stderrWriter: { events.append("stderr:\($0)") },
            exit: { _ in },
            exec: { _, _ in events.append("exec") }
        )

        // execがreturnした (フェイクは常にreturnする) ため、exec呼び出しの後に失敗メッセージも
        // 書かれる。ここで検証したいのはバージョン不一致の案内がexecより前に書かれることのみ。
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events[0].contains("run 'yobirin install'"))
        XCTAssertTrue(events[0].contains("0.9.0"))
        XCTAssertTrue(events[0].contains("1.0.0"))
        XCTAssertEqual(events[1], "exec")
    }

    // MARK: - exec失敗 (Requirement 17.5)

    func testExecReturningIsTreatedAsFailureAndExitsWithEnvironmentErrorExitCode() {
        let naming = makeFakeBundle(version: "1.0.0")
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []

        BundleHandoff.execDefaultBundle(
            naming: naming,
            arguments: ["/old/yobirin"],
            currentVersion: "1.0.0",
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) },
            exec: { _, _ in }  // execvが返ってきた (失敗) ことを模す。
        )

        XCTAssertEqual(exitCodes, [ResultEmitter.environmentErrorExitCode])
        XCTAssertEqual(stderrMessages.count, 1)
    }
}
