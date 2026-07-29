import UserNotifications
import XCTest

@testable import yobirin

final class DoctorCommandTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "yobirin-doctor-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - フィクスチャ

    /// `~/Applications/<appName>.app` にInfo.plistとMach-Oを持つバンドルを作る。
    @discardableResult
    private func makeBundle(appName: String, version: String) throws -> String {
        let bundlePath = "\(root!)/Applications/\(appName).app"
        try FileManager.default.createDirectory(
            atPath: "\(bundlePath)/Contents/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.mjun0812.yobirin",
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: "\(bundlePath)/Contents/Info.plist"))
        FileManager.default.createFile(atPath: "\(bundlePath)/Contents/MacOS/yobirin", contents: Data())
        return bundlePath
    }

    private func makeBinDirectory() throws -> String {
        let path = "\(root!)/.local/bin"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func collect(binDirectory: String, currentVersion: String = "1.1.0") -> [DoctorCommand.Check] {
        DoctorCommand.collectChecks(
            currentVersion: currentVersion,
            homeDirectory: root,
            binDirectory: binDirectory,
            fileManager: .default,
            listDirectory: { try FileManager.default.contentsOfDirectory(atPath: $0) }
        )
    }

    private func check(_ checks: [DoctorCommand.Check], named name: String) throws -> DoctorCommand.Check {
        try XCTUnwrap(checks.first { $0.name == name }, "診断項目 \(name) が無い")
    }

    // MARK: - インストール済みバンドル (Requirement 15.1)

    func testReportsInstalledBundleWithVersion() throws {
        try makeBundle(appName: "Yobirin", version: "1.1.0")
        let bin = try makeBinDirectory()

        let bundle = try check(collect(binDirectory: bin), named: "bundle")

        XCTAssertEqual(bundle.status, .ok)
        XCTAssertTrue(bundle.detail.contains("1.1.0"), "バージョンが報告されていない: \(bundle.detail)")
        XCTAssertNil(bundle.remedy)
    }

    func testReportsMissingBundleAsFailureWithRemedy() throws {
        let bin = try makeBinDirectory()

        let bundle = try check(collect(binDirectory: bin), named: "bundle")

        XCTAssertEqual(bundle.status, .failure)
        XCTAssertEqual(bundle.remedy?.contains("yobirin install"), true, "対処が案内されていない")
    }

    func testListsProfileBundles() throws {
        try makeBundle(appName: "Yobirin", version: "1.1.0")
        try makeBundle(appName: "Yobirin-Claude", version: "1.1.0")
        try makeBundle(appName: "Yobirin-Codex", version: "1.1.0")
        let bin = try makeBinDirectory()

        let profiles = try check(collect(binDirectory: bin), named: "profiles")

        XCTAssertEqual(profiles.status, .ok)
        XCTAssertTrue(profiles.detail.contains("claude"), profiles.detail)
        XCTAssertTrue(profiles.detail.contains("codex"), profiles.detail)
    }

    /// プロファイルが1つも無い状態は正常 (design.md 診断項目の表)。
    func testNoProfilesIsNotAProblem() throws {
        try makeBundle(appName: "Yobirin", version: "1.1.0")
        let bin = try makeBinDirectory()

        let profiles = try check(collect(binDirectory: bin), named: "profiles")

        XCTAssertEqual(profiles.status, .ok)
    }

    // MARK: - バージョンの一致 (Requirement 15.2)

    func testReportsMatchingVersionAsOk() throws {
        try makeBundle(appName: "Yobirin", version: "1.1.0")
        let bin = try makeBinDirectory()

        let version = try check(collect(binDirectory: bin, currentVersion: "1.1.0"), named: "version")

        XCTAssertEqual(version.status, .ok)
    }

    func testReportsVersionMismatchAsWarningWithRemedy() throws {
        try makeBundle(appName: "Yobirin", version: "1.0.1")
        let bin = try makeBinDirectory()

        let version = try check(collect(binDirectory: bin, currentVersion: "1.1.0"), named: "version")

        XCTAssertEqual(version.status, .warning)
        XCTAssertTrue(version.detail.contains("1.0.1"), version.detail)
        XCTAssertTrue(version.detail.contains("1.1.0"), version.detail)
        XCTAssertEqual(version.remedy?.contains("yobirin install"), true)
    }

    /// バンドルが無ければ比較対象が存在しない。判定不能として扱い、問題には数えない。
    func testVersionIsUnknownWhenBundleIsMissing() throws {
        let bin = try makeBinDirectory()

        let version = try check(collect(binDirectory: bin), named: "version")

        XCTAssertEqual(version.status, .unknown)
    }

    // MARK: - PATH上のリンク (Requirement 15.3)

    func testReportsHealthyLinkAsOk() throws {
        let bundlePath = try makeBundle(appName: "Yobirin", version: "1.1.0")
        let bin = try makeBinDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: "\(bin)/yobirin", withDestinationPath: "\(bundlePath)/Contents/MacOS/yobirin")

        let link = try check(collect(binDirectory: bin), named: "link")

        XCTAssertEqual(link.status, .ok)
        XCTAssertTrue(link.detail.contains(bin), link.detail)
    }

    func testReportsMissingLinkAsWarningWithRemedy() throws {
        try makeBundle(appName: "Yobirin", version: "1.1.0")
        let bin = try makeBinDirectory()

        let link = try check(collect(binDirectory: bin), named: "link")

        XCTAssertEqual(link.status, .warning)
        XCTAssertEqual(link.remedy?.contains("yobirin install"), true)
    }

    /// 壊れたリンクは `fileExists` がsymlinkを辿るため「存在しない」と誤判定される。
    /// リンク自体の有無は lstat 相当で見る必要がある (Installerと同じ作法)。
    func testReportsDanglingLinkAsWarning() throws {
        try makeBundle(appName: "Yobirin", version: "1.1.0")
        let bin = try makeBinDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: "\(bin)/yobirin", withDestinationPath: "\(root!)/Applications/Gone.app/Contents/MacOS/yobirin")

        let link = try check(collect(binDirectory: bin), named: "link")

        XCTAssertEqual(link.status, .warning)
        XCTAssertTrue(link.detail.lowercased().contains("dangling") || link.detail.contains("Gone.app"), link.detail)
    }

    // MARK: - bin ディレクトリ解決の共有 (design.md: パス組み立てを重複させない)

    func testBinDirectoryDefaultsToLocalBinUnderHome() throws {
        XCTAssertEqual(
            Installer.resolvedBinDirectory(homeDirectory: "/home/u", environment: [:]),
            "/home/u/.local/bin")
    }

    func testBinDirectoryHonorsEnvironmentOverride() throws {
        XCTAssertEqual(
            Installer.resolvedBinDirectory(
                homeDirectory: "/home/u",
                environment: [Installer.binDirectoryEnvironmentKey: "/opt/bin"]),
            "/opt/bin")
    }
}

// MARK: - 整形と終了コード (Requirements 15.7, 15.8, 15.9)

final class DoctorCommandOutputTests: XCTestCase {
    private func ok(_ name: String) -> DoctorCommand.Check {
        DoctorCommand.Check(name: name, status: .ok, detail: "fine", remedy: nil)
    }

    private func warning(_ name: String) -> DoctorCommand.Check {
        DoctorCommand.Check(name: name, status: .warning, detail: "stale", remedy: "Run 'yobirin install'.")
    }

    private func failure(_ name: String) -> DoctorCommand.Check {
        DoctorCommand.Check(name: name, status: .failure, detail: "absent", remedy: "Run 'yobirin install'.")
    }

    private func unknown(_ name: String) -> DoctorCommand.Check {
        DoctorCommand.Check(name: name, status: .unknown, detail: "cannot tell", remedy: nil)
    }

    private func run(json: Bool, _ checks: [DoctorCommand.Check]) -> (output: String, exitCode: Int32?) {
        var output = ""
        var code: Int32?
        DoctorCommand.perform(
            json: json, checks: checks, stdoutWriter: { output = $0 }, exit: { code = $0 })
        return (output, code)
    }

    // MARK: 終了コード

    func testExitsZeroWhenNoProblemsAreFound() throws {
        XCTAssertEqual(run(json: false, [ok("bundle"), ok("link")]).exitCode, 0)
    }

    func testExitsNonZeroWhenAWarningIsFound() throws {
        let code = try XCTUnwrap(run(json: false, [ok("bundle"), warning("version")]).exitCode)
        XCTAssertNotEqual(code, 0)
    }

    func testExitsNonZeroWhenAFailureIsFound() throws {
        let code = try XCTUnwrap(run(json: false, [failure("bundle")]).exitCode)
        XCTAssertNotEqual(code, 0)
    }

    /// 判定不能は問題として数えない (Requirement 15.5)。
    func testUnknownDoesNotCountAsAProblem() throws {
        XCTAssertEqual(run(json: false, [ok("bundle"), unknown("permission")]).exitCode, 0)
    }

    // MARK: テスト出力

    func testTextOutputListsEveryCheck() throws {
        let output = run(json: false, [ok("bundle"), warning("version"), unknown("permission")]).output

        for name in ["bundle", "version", "permission"] {
            XCTAssertTrue(output.contains(name), "\(name) が出力にない:\n\(output)")
        }
    }

    func testTextOutputShowsRemedyForProblems() throws {
        let output = run(json: false, [warning("version")]).output
        XCTAssertTrue(output.contains("Run 'yobirin install'."), output)
    }

    func testTextOutputReportsNoProblemsWhenHealthy() throws {
        let output = run(json: false, [ok("bundle"), unknown("permission")]).output
        XCTAssertTrue(output.lowercased().contains("no problems"), output)
    }

    func testTextOutputReportsTheProblemCount() throws {
        let output = run(json: false, [warning("version"), failure("bundle")]).output
        XCTAssertTrue(output.contains("2"), output)
    }

    // MARK: 機械可読出力

    func testJSONOutputContainsEveryCheckAndProblemCount() throws {
        let output = run(json: true, [ok("bundle"), warning("version"), unknown("permission")]).output
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
            "JSONとして解釈できない: \(output)")

        let checks = try XCTUnwrap(parsed["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.count, 3)
        XCTAssertEqual(checks.map { $0["name"] as? String }, ["bundle", "version", "permission"])
        XCTAssertEqual(checks.map { $0["status"] as? String }, ["ok", "warning", "unknown"])
        XCTAssertEqual(parsed["problems"] as? Int, 1)
    }

    func testJSONOutputUsesNullForAbsentRemedy() throws {
        let output = run(json: true, [ok("bundle")]).output
        XCTAssertTrue(output.contains("\"remedy\":null"), output)
    }

    func testJSONOutputEscapesDetailText() throws {
        let check = DoctorCommand.Check(
            name: "bundle", status: .ok, detail: "path with \"quotes\"", remedy: nil)
        let output = run(json: true, [check]).output

        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let checks = try XCTUnwrap(parsed["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first?["detail"] as? String, "path with \"quotes\"")
    }
}

// MARK: - 通知許可の判定 (Requirements 15.4, 15.5)

/// 許可状態のみを注入するスタブ。`requestAuthorization` が呼ばれたら記録する
/// (診断が許可を要求してはならないことの検証用)。
private final class StubPermissionClient: NotificationCenterClient, @unchecked Sendable {
    private let status: UNAuthorizationStatus
    private let deliversResult: Bool
    private(set) var requestAuthorizationCallCount = 0
    private(set) var getAuthorizationStatusCallCount = 0

    init(status: UNAuthorizationStatus, deliversResult: Bool = true) {
        self.status = status
        self.deliversResult = deliversResult
    }

    func requestAuthorization(completionHandler: @escaping (Bool, Error?) -> Void) {
        requestAuthorizationCallCount += 1
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func add(_ request: UNNotificationRequest, completionHandler: ((Error?) -> Void)?) {}
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {}

    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        getAuthorizationStatusCallCount += 1
        guard deliversResult else { return }
        let status = status
        DispatchQueue.global().async { completionHandler(status) }
    }
}

final class DoctorCommandPermissionTests: XCTestCase {
    func testReportsAuthorizedAsOk() throws {
        let client = StubPermissionClient(status: .authorized)
        let check = DoctorCommand.permissionCheck(isOutsideBundle: false, client: client)

        XCTAssertEqual(check.name, "permission")
        XCTAssertEqual(check.status, .ok)
        XCTAssertNil(check.remedy)
    }

    func testReportsDeniedAsFailureWithSystemSettingsGuidance() throws {
        let client = StubPermissionClient(status: .denied)
        let check = DoctorCommand.permissionCheck(isOutsideBundle: false, client: client)

        XCTAssertEqual(check.status, .failure)
        let remedy = try XCTUnwrap(check.remedy)
        XCTAssertTrue(remedy.contains("System Settings"), remedy)
        XCTAssertTrue(remedy.contains("Yobirin"), remedy)
    }

    func testReportsNotDeterminedAsWarning() throws {
        let client = StubPermissionClient(status: .notDetermined)
        let check = DoctorCommand.permissionCheck(isOutsideBundle: false, client: client)

        XCTAssertEqual(check.status, .warning)
        XCTAssertNotNil(check.remedy)
    }

    /// 診断は許可を要求してはならない。要求すると未許可の初回に許可ダイアログが出る。
    func testNeverRequestsAuthorization() throws {
        let client = StubPermissionClient(status: .denied)
        _ = DoctorCommand.permissionCheck(isOutsideBundle: false, client: client)

        XCTAssertEqual(client.requestAuthorizationCallCount, 0)
        XCTAssertEqual(client.getAuthorizationStatusCallCount, 1)
    }

    // MARK: バンドル外 (Requirement 15.5)

    func testReportsUnknownOutsideTheBundleWithoutTouchingTheNotificationAPI() throws {
        let client = StubPermissionClient(status: .authorized)
        let check = DoctorCommand.permissionCheck(isOutsideBundle: true, client: client)

        XCTAssertEqual(check.status, .unknown)
        XCTAssertEqual(client.getAuthorizationStatusCallCount, 0, "バンドル外で通知APIを呼んでいる")
    }

    /// 判定不能は問題として数えないため、バンドル外でも診断自体は完了できる。
    func testUnknownPermissionDoesNotMakeTheDiagnosisFail() throws {
        let client = StubPermissionClient(status: .authorized)
        let check = DoctorCommand.permissionCheck(isOutsideBundle: true, client: client)

        var code: Int32?
        DoctorCommand.perform(json: false, checks: [check], stdoutWriter: { _ in }, exit: { code = $0 })

        XCTAssertEqual(code, 0)
    }

    /// 応答が返らない場合もハングせずタイムアウトで判定不能に落ちる。
    func testFallsBackToUnknownWhenTheStatusNeverArrives() throws {
        let client = StubPermissionClient(status: .authorized, deliversResult: false)
        let check = DoctorCommand.permissionCheck(
            isOutsideBundle: false, client: client, timeout: .milliseconds(50))

        XCTAssertEqual(check.status, .unknown)
    }
}

// MARK: - 走査の失敗を0件と丸めない (kiro-review: エラーの握り潰し防止)

final class DoctorCommandScanFailureTests: XCTestCase {
    private struct ScanError: Error {}

    func testUnreadableApplicationsDirectoryIsReportedAsUnknownNotAsZeroProfiles() throws {
        let root = NSTemporaryDirectory() + "yobirin-doctor-scan-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: "\(root)/Applications", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let checks = DoctorCommand.collectChecks(
            currentVersion: "1.1.0",
            homeDirectory: root,
            binDirectory: "\(root)/.local/bin",
            fileManager: .default,
            listDirectory: { _ in throw ScanError() }
        )
        let profiles = try XCTUnwrap(checks.first { $0.name == "profiles" })

        XCTAssertEqual(profiles.status, .unknown)
        XCTAssertFalse(profiles.detail.contains("No profile bundles"), profiles.detail)
    }

    /// ディレクトリ自体が無い場合は0件と同義であり、問題ではない。
    func testMissingApplicationsDirectoryIsStillOk() throws {
        let root = NSTemporaryDirectory() + "yobirin-doctor-none-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let checks = DoctorCommand.collectChecks(
            currentVersion: "1.1.0",
            homeDirectory: root,
            binDirectory: "\(root)/.local/bin",
            fileManager: .default,
            listDirectory: { try FileManager.default.contentsOfDirectory(atPath: $0) }
        )
        let profiles = try XCTUnwrap(checks.first { $0.name == "profiles" })

        XCTAssertEqual(profiles.status, .ok)
    }
}
