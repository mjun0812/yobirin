import XCTest

@testable import yobirin

/// `install` サブコマンドのパース・プロファイル名バリデーション・インストーラ呼び出しの結線を
/// 検証する (design.md CLI契約 > install、Requirements 9.1, 9.3, 11.1)。
///
/// 実ファイルシステムへの副作用は行わず、`Installer.install` 呼び出しは注入したfakeで検証する。
final class InstallCommandTests: XCTestCase {
    // MARK: - Parsing (Requirement 11.1)

    func testParsesWithNoOptions() throws {
        let command = try InstallCommand.parse([])
        XCTAssertNil(command.profile)
        XCTAssertNil(command.icon)
    }

    func testParsesProfileAndIcon() throws {
        let command = try InstallCommand.parse([
            "--profile", "claude", "--icon", "/tmp/icon.png",
        ])
        XCTAssertEqual(command.profile, "claude")
        XCTAssertEqual(command.icon, "/tmp/icon.png")
    }

    func testRootCommandResolvesInstallSubcommand() throws {
        let parsed = try YobirinCommand.parseAsRoot(["install", "--profile", "claude"])
        guard let install = parsed as? InstallCommand else {
            XCTFail("`install` はInstallCommandへ解決されるべき")
            return
        }
        XCTAssertEqual(install.profile, "claude")
    }

    // MARK: - Profile name validation (same `^[a-z0-9]+$` convention as ProfileNaming)

    func testPerformWithInvalidProfileNameWritesStderrAndExitsWithoutCallingInstall() {
        var installCalls: [(String?, String?)] = []
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []

        InstallCommand.perform(
            profile: "ABC",
            icon: nil,
            install: { profile, icon in installCalls.append((profile, icon)) },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) }
        )

        XCTAssertTrue(installCalls.isEmpty)
        XCTAssertEqual(exitCodes, [ResultEmitter.environmentErrorExitCode])
        XCTAssertEqual(stderrMessages.count, 1)
        XCTAssertTrue(stderrMessages[0].contains("ABC"))
    }

    func testPerformWithHyphenatedProfileNameWritesStderrAndExitsWithoutCallingInstall() {
        var installCalls: [(String?, String?)] = []
        var exitCodes: [Int32] = []

        InstallCommand.perform(
            profile: "a-b",
            icon: nil,
            install: { profile, icon in installCalls.append((profile, icon)) },
            stderrWriter: { _ in },
            exit: { exitCodes.append($0) }
        )

        XCTAssertTrue(installCalls.isEmpty)
        XCTAssertEqual(exitCodes, [ResultEmitter.environmentErrorExitCode])
    }

    func testPerformWithNilProfileSkipsValidationAndCallsInstall() {
        var installCalls: [(String?, String?)] = []
        var exitCodes: [Int32] = []

        InstallCommand.perform(
            profile: nil,
            icon: nil,
            install: { profile, icon in installCalls.append((profile, icon)) },
            stderrWriter: { _ in },
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(installCalls.count, 1)
        XCTAssertTrue(exitCodes.isEmpty)
    }

    // MARK: - Argument pass-through to Installer (fake injection)

    func testPerformPassesProfileAndIconThroughToInstall() {
        var installCalls: [(String?, String?)] = []

        InstallCommand.perform(
            profile: "claude",
            icon: "/tmp/icon.png",
            install: { profile, icon in installCalls.append((profile, icon)) },
            stderrWriter: { _ in },
            exit: { _ in }
        )

        XCTAssertEqual(installCalls.count, 1)
        XCTAssertEqual(installCalls.first?.0, "claude")
        XCTAssertEqual(installCalls.first?.1, "/tmp/icon.png")
    }

    func testPerformWithoutIconPassesNilIconThroughToInstall() {
        var installCalls: [(String?, String?)] = []

        InstallCommand.perform(
            profile: nil,
            icon: nil,
            install: { profile, icon in installCalls.append((profile, icon)) },
            stderrWriter: { _ in },
            exit: { _ in }
        )

        XCTAssertEqual(installCalls.count, 1)
        XCTAssertNil(installCalls.first?.0)
        XCTAssertNil(installCalls.first?.1)
    }

    // MARK: - Installer error mapping (design.md Error Handling)

    func testPerformWhenInstallThrowsInstallErrorWritesJapaneseMessageAndExitsNonZero() {
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []
        let missingIconPath = "/tmp/does-not-exist.png"

        InstallCommand.perform(
            profile: nil,
            icon: missingIconPath,
            install: { _, _ in
                throw Installer.InstallError.iconUnreadable(path: missingIconPath)
            },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) }
        )

        XCTAssertEqual(exitCodes, [ResultEmitter.environmentErrorExitCode])
        XCTAssertEqual(stderrMessages.count, 1)
        XCTAssertTrue(stderrMessages[0].contains(missingIconPath))
    }

    func testPerformWhenInstallSucceedsDoesNotWriteStderrOrExit() {
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []

        InstallCommand.perform(
            profile: nil,
            icon: nil,
            install: { _, _ in },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) }
        )

        XCTAssertTrue(stderrMessages.isEmpty)
        XCTAssertTrue(exitCodes.isEmpty)
    }
}
