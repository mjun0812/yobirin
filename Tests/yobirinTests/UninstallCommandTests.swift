import XCTest

@testable import yobirin

/// `uninstall` サブコマンドのパース・プロファイル名バリデーション・インストーラ呼び出しの結線を
/// 検証する (design.md CLI契約 > uninstall、Requirement 19)。
///
/// 実ファイルシステムへの副作用は行わず、`Installer.uninstall` 呼び出しは注入したfakeで検証する。
final class UninstallCommandTests: XCTestCase {
    private func makeOutcome(
        danglingLinkPath: String? = nil,
        unregisterFailureExitCode: Int32? = nil
    ) -> Installer.UninstallOutcome {
        Installer.UninstallOutcome(
            danglingLinkPath: danglingLinkPath,
            unregisterFailureExitCode: unregisterFailureExitCode)
    }

    // MARK: - Parsing

    func testParsesWithNoOptions() throws {
        let command = try UninstallCommand.parse([])
        XCTAssertNil(command.profile)
    }

    func testParsesProfile() throws {
        let command = try UninstallCommand.parse(["--profile", "codex"])
        XCTAssertEqual(command.profile, "codex")
    }

    func testRootCommandResolvesUninstallSubcommand() throws {
        let parsed = try YobirinCommand.parseAsRoot(["uninstall", "--profile", "codex"])
        guard let uninstall = parsed as? UninstallCommand else {
            XCTFail("`uninstall` はUninstallCommandへ解決されるべき")
            return
        }
        XCTAssertEqual(uninstall.profile, "codex")
    }

    // MARK: - Profile name validation (Requirement 19.5)

    func testPerformWithInvalidProfileNameWritesStderrAndExitsWithoutCallingUninstall() {
        var uninstallCalls: [String?] = []
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []

        UninstallCommand.perform(
            profile: "Codex",
            uninstall: { profile in
                uninstallCalls.append(profile)
                return self.makeOutcome()
            },
            stdoutWriter: { _ in },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) }
        )

        XCTAssertTrue(uninstallCalls.isEmpty, "検証前にアンインストールを呼んではならない")
        XCTAssertEqual(exitCodes, [ResultEmitter.environmentErrorExitCode])
        XCTAssertEqual(stderrMessages.count, 1)
        XCTAssertTrue(stderrMessages[0].contains("Codex"))
    }

    // MARK: - Success path (Requirement 19.1)

    func testPerformPassesProfileThroughAndReportsRemovedBundlePath() {
        var uninstallCalls: [String?] = []
        var stdoutMessages: [String] = []
        var exitCodes: [Int32] = []

        UninstallCommand.perform(
            profile: "codex",
            uninstall: { profile in
                uninstallCalls.append(profile)
                return self.makeOutcome()
            },
            stdoutWriter: { stdoutMessages.append($0) },
            stderrWriter: { _ in },
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(uninstallCalls, ["codex"])
        XCTAssertTrue(exitCodes.isEmpty, "成功時はexitを呼ばない (終了コード0)")
        XCTAssertEqual(stdoutMessages.count, 1)
        XCTAssertTrue(stdoutMessages[0].hasPrefix("Uninstalled: "))
        XCTAssertTrue(stdoutMessages[0].hasSuffix("Yobirin-Codex.app"))
    }

    // MARK: - Failure path (Requirement 19.4)

    func testPerformWithMissingBundleWritesStderrAndExitsNonZero() {
        var stdoutMessages: [String] = []
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []

        UninstallCommand.perform(
            profile: nil,
            uninstall: { _ in
                throw Installer.InstallError.bundleNotInstalled(
                    path: "/Users/you/Applications/Yobirin.app")
            },
            stdoutWriter: { stdoutMessages.append($0) },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(exitCodes, [ResultEmitter.environmentErrorExitCode])
        XCTAssertEqual(stderrMessages, ["Not installed: /Users/you/Applications/Yobirin.app"])
        XCTAssertTrue(stdoutMessages.isEmpty, "失敗時にstdoutへ成功メッセージを書いてはならない")
    }

    // MARK: - Dangling symlink guidance (Requirement 19.7)

    func testPerformGuidesAboutTheRemainingSymlinkWithoutChangingTheExitCode() {
        var stdoutMessages: [String] = []
        var exitCodes: [Int32] = []

        UninstallCommand.perform(
            profile: nil,
            uninstall: { _ in self.makeOutcome(danglingLinkPath: "/Users/you/.local/bin/yobirin") },
            stdoutWriter: { stdoutMessages.append($0) },
            stderrWriter: { _ in },
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(stdoutMessages.count, 2)
        XCTAssertTrue(stdoutMessages[0].hasPrefix("Uninstalled: "))
        XCTAssertTrue(stdoutMessages[1].contains("/Users/you/.local/bin/yobirin"))
        XCTAssertTrue(exitCodes.isEmpty, "案内の有無は終了コードを変えてはならない")
    }

    func testPerformDoesNotGuideWhenNoSymlinkRemains() {
        var stdoutMessages: [String] = []

        UninstallCommand.perform(
            profile: nil,
            uninstall: { _ in self.makeOutcome() },
            stdoutWriter: { stdoutMessages.append($0) },
            stderrWriter: { _ in },
            exit: { _ in }
        )

        XCTAssertEqual(stdoutMessages.count, 1)
        XCTAssertTrue(stdoutMessages[0].hasPrefix("Uninstalled: "))
    }

    // MARK: - Unregister failure (Requirement 19.8)

    func testPerformWarnsOnUnregisterFailureButStillReportsSuccess() {
        var stdoutMessages: [String] = []
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []

        UninstallCommand.perform(
            profile: nil,
            uninstall: { _ in self.makeOutcome(unregisterFailureExitCode: 7) },
            stdoutWriter: { stdoutMessages.append($0) },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(stdoutMessages.count, 1)
        XCTAssertTrue(stdoutMessages[0].hasPrefix("Uninstalled: "))
        XCTAssertEqual(stderrMessages.count, 1)
        XCTAssertTrue(stderrMessages[0].contains("7"))
        XCTAssertTrue(exitCodes.isEmpty, "登録解除の失敗は削除の成否を変えてはならない")
    }
}
