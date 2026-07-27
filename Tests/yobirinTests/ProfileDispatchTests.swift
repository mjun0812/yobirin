import Foundation
import XCTest

@testable import yobirin

/// プロファイル規約 (`ProfileNaming`) とディスパッチ (`ProfileDispatch`) のテスト
/// (design.md フローに関する決定、Requirements 10.4, 10.5)。
final class ProfileDispatchTests: XCTestCase {
    // MARK: - ProfileNaming: derivation

    func testDefaultDerivesYobirinNaming() {
        let naming = ProfileNaming.default(homeDirectory: "/Users/mjun")

        XCTAssertEqual(naming.appName, "Yobirin")
        XCTAssertEqual(naming.bundleID, "com.mjun0812.yobirin")
        XCTAssertEqual(naming.bundlePath, "/Users/mjun/Applications/Yobirin.app")
        XCTAssertEqual(naming.machOPath, "/Users/mjun/Applications/Yobirin.app/Contents/MacOS/yobirin")
    }

    func testForProfileDerivesCapitalizedAppNameAndScopedBundleID() throws {
        let naming = try ProfileNaming.forProfile("claude", homeDirectory: "/Users/mjun")

        XCTAssertEqual(naming.appName, "Yobirin-Claude")
        XCTAssertEqual(naming.bundleID, "com.mjun0812.yobirin.claude")
        XCTAssertEqual(naming.bundlePath, "/Users/mjun/Applications/Yobirin-Claude.app")
        XCTAssertEqual(
            naming.machOPath, "/Users/mjun/Applications/Yobirin-Claude.app/Contents/MacOS/yobirin")
    }

    func testForProfileWithSingleCharacterCapitalizes() throws {
        let naming = try ProfileNaming.forProfile("x", homeDirectory: "/Users/mjun")
        XCTAssertEqual(naming.appName, "Yobirin-X")
    }

    func testResolveWithNilProfileReturnsDefault() throws {
        let naming = try ProfileNaming.resolve(profile: nil, homeDirectory: "/Users/mjun")
        XCTAssertEqual(naming.appName, "Yobirin")
    }

    func testResolveWithProfileDelegatesToForProfile() throws {
        let naming = try ProfileNaming.resolve(profile: "codex", homeDirectory: "/Users/mjun")
        XCTAssertEqual(naming.appName, "Yobirin-Codex")
    }

    // MARK: - ProfileNaming: validation (^[a-z0-9]+$)

    func testForProfileAcceptsLowercaseAlphanumeric() throws {
        XCTAssertNoThrow(try ProfileNaming.forProfile("claude123"))
    }

    func testForProfileRejectsUppercase() {
        XCTAssertThrowsError(try ProfileNaming.forProfile("Claude"))
    }

    func testForProfileRejectsHyphen() {
        XCTAssertThrowsError(try ProfileNaming.forProfile("claude-code"))
    }

    func testForProfileRejectsSlash() {
        XCTAssertThrowsError(try ProfileNaming.forProfile("../etc"))
    }

    func testForProfileRejectsEmptyString() {
        XCTAssertThrowsError(try ProfileNaming.forProfile(""))
    }

    func testForProfileRejectsWhitespace() {
        XCTAssertThrowsError(try ProfileNaming.forProfile("cla ude"))
    }

    // MARK: - ProfileNaming.recognize: reverse lookup (往復一致, Requirement 14.7)

    func testRecognizeYobirinAppAsDefault() {
        XCTAssertEqual(
            ProfileNaming.recognize(appDirectoryName: "Yobirin.app", homeDirectory: "/Users/mjun"),
            .default)
    }

    func testRecognizeYobirinClaudeAppAsProfileClaude() {
        XCTAssertEqual(
            ProfileNaming.recognize(
                appDirectoryName: "Yobirin-Claude.app", homeDirectory: "/Users/mjun"),
            .profile("claude"))
    }

    func testRecognizeRejectsUppercaseSuffixThatDoesNotRoundTrip() {
        // 順方向導出は "claude" -> "Yobirin-Claude" のように先頭のみ大文字化するため、
        // "Yobirin-ABC.app" は逆引きした "abc" からの順方向導出 "Yobirin-Abc" と一致せず棄却される。
        XCTAssertNil(
            ProfileNaming.recognize(appDirectoryName: "Yobirin-ABC.app", homeDirectory: "/Users/mjun"))
    }

    func testRecognizeRejectsHyphenatedInnerNameInvalidAsProfile() {
        XCTAssertNil(
            ProfileNaming.recognize(
                appDirectoryName: "Yobirin-My-App.app", homeDirectory: "/Users/mjun"))
    }

    func testRecognizeRejectsUnrelatedAppName() {
        XCTAssertNil(
            ProfileNaming.recognize(appDirectoryName: "Other.app", homeDirectory: "/Users/mjun"))
    }

    func testRecognizeRejectsNonAppSuffix() {
        XCTAssertNil(
            ProfileNaming.recognize(appDirectoryName: "Yobirin", homeDirectory: "/Users/mjun"))
    }

    func testRecognizeRejectsEmptyProfileSuffix() {
        XCTAssertNil(
            ProfileNaming.recognize(appDirectoryName: "Yobirin-.app", homeDirectory: "/Users/mjun"))
    }

    // MARK: - ProfileDispatch.buildExecArguments (pure function, Requirement 10.4)

    func testBuildExecArgumentsReplacesArgv0AndPassesThroughOtherArguments() {
        let result = ProfileDispatch.buildExecArguments(
            machOPath: "/target/yobirin",
            arguments: ["/old/yobirin", "--title", "t", "--message", "m"]
        )
        XCTAssertEqual(result, ["/target/yobirin", "--title", "t", "--message", "m"])
    }

    func testBuildExecArgumentsStripsSpaceSeparatedProfileFlag() {
        let result = ProfileDispatch.buildExecArguments(
            machOPath: "/target/yobirin",
            arguments: ["/old/yobirin", "--title", "t", "--profile", "claude", "--message", "m"]
        )
        XCTAssertEqual(result, ["/target/yobirin", "--title", "t", "--message", "m"])
        XCTAssertFalse(result.contains("--profile"))
        XCTAssertFalse(result.contains("claude"))
    }

    func testBuildExecArgumentsStripsEqualsSeparatedProfileFlag() {
        let result = ProfileDispatch.buildExecArguments(
            machOPath: "/target/yobirin",
            arguments: ["/old/yobirin", "--title", "t", "--profile=claude", "--message", "m"]
        )
        XCTAssertEqual(result, ["/target/yobirin", "--title", "t", "--message", "m"])
    }

    func testBuildExecArgumentsWithProfileAtEndDropsDanglingValue() {
        let result = ProfileDispatch.buildExecArguments(
            machOPath: "/target/yobirin",
            arguments: ["/old/yobirin", "--title", "t", "--profile", "claude"]
        )
        XCTAssertEqual(result, ["/target/yobirin", "--title", "t"])
    }

    func testBuildExecArgumentsWithNoProfileFlagIsUnchangedAsideFromArgv0() {
        let result = ProfileDispatch.buildExecArguments(
            machOPath: "/target/yobirin",
            arguments: ["/old/yobirin", "notify", "--title", "t", "--message", "m"]
        )
        XCTAssertEqual(result, ["/target/yobirin", "notify", "--title", "t", "--message", "m"])
    }

    // MARK: - ProfileDispatch.dispatch: not-installed branch (Requirement 10.5 / 7.3)

    func testDispatchWhenNotInstalledWritesStderrAndExitsNonZeroWithoutExec() {
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []
        var execCalls: [(String, [String])] = []

        ProfileDispatch.dispatch(
            profile: "claude",
            arguments: ["/old/yobirin", "--title", "t", "--message", "m"],
            homeDirectory: "/Users/mjun",
            isInstalled: { _ in false },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) },
            exec: { path, args in execCalls.append((path, args)) }
        )

        XCTAssertTrue(execCalls.isEmpty)
        XCTAssertEqual(exitCodes.count, 1)
        XCTAssertNotEqual(exitCodes.first, 0)
        XCTAssertEqual(stderrMessages.count, 1)
        XCTAssertTrue(stderrMessages[0].contains("claude"))
    }

    func testDispatchWhenProfileNameInvalidWritesStderrAndExitsNonZeroWithoutExec() {
        var stderrMessages: [String] = []
        var exitCodes: [Int32] = []
        var execCalls: [(String, [String])] = []

        ProfileDispatch.dispatch(
            profile: "Claude!",
            arguments: ["/old/yobirin", "--title", "t", "--message", "m"],
            homeDirectory: "/Users/mjun",
            isInstalled: { _ in true },
            stderrWriter: { stderrMessages.append($0) },
            exit: { exitCodes.append($0) },
            exec: { path, args in execCalls.append((path, args)) }
        )

        XCTAssertTrue(execCalls.isEmpty)
        XCTAssertEqual(exitCodes.count, 1)
        XCTAssertNotEqual(exitCodes.first, 0)
        XCTAssertEqual(stderrMessages.count, 1)
    }

    // MARK: - ProfileDispatch.dispatch: installed branch calls exec with the built arguments

    func testDispatchWhenInstalledCallsExecWithTargetMachOAndStrippedArguments() {
        var execCalls: [(String, [String])] = []
        var exitCodes: [Int32] = []

        ProfileDispatch.dispatch(
            profile: "claude",
            arguments: ["/old/yobirin", "--title", "t", "--profile", "claude", "--message", "m"],
            homeDirectory: "/Users/mjun",
            isInstalled: { _ in true },
            stderrWriter: { _ in },
            exit: { exitCodes.append($0) },
            exec: { path, args in execCalls.append((path, args)) }
        )

        XCTAssertEqual(execCalls.count, 1)
        XCTAssertEqual(execCalls.first?.0, "/Users/mjun/Applications/Yobirin-Claude.app/Contents/MacOS/yobirin")
        XCTAssertEqual(
            execCalls.first?.1,
            [
                "/Users/mjun/Applications/Yobirin-Claude.app/Contents/MacOS/yobirin",
                "--title", "t", "--message", "m",
            ]
        )
        // execがreturnした場合 (モックは常にreturnする) は失敗として非0終了する。
        XCTAssertEqual(exitCodes.count, 1)
        XCTAssertNotEqual(exitCodes.first, 0)
    }

    func testDispatchChecksInstalledUsingDerivedMachOPath() {
        var checkedPaths: [String] = []

        ProfileDispatch.dispatch(
            profile: "codex",
            arguments: ["/old/yobirin"],
            homeDirectory: "/Users/mjun",
            isInstalled: { path in
                checkedPaths.append(path)
                return false
            },
            stderrWriter: { _ in },
            exit: { _ in },
            exec: { _, _ in }
        )

        XCTAssertEqual(
            checkedPaths, ["/Users/mjun/Applications/Yobirin-Codex.app/Contents/MacOS/yobirin"])
    }
}
