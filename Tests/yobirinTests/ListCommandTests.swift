import Foundation
import XCTest

@testable import yobirin

/// `list` サブコマンド (`ListCommand`) のテスト (design.md ListCommand、Requirements
/// 14.1〜14.9)。
///
/// テンポラリ領域に偽バンドル (ディレクトリ + Info.plist) を構成して検証する。実
/// `~/Applications` へは一切触れない。
final class ListCommandTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-list-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    private var homeDirectory: String { tempRoot.appendingPathComponent("home").path }
    private var applicationsDirectory: URL {
        tempRoot.appendingPathComponent("home/Applications")
    }

    /// `<applicationsDirectory>/<appDirectoryName>` を偽バンドルとして組み立てる。
    /// `bundleID` / `version` が nil のキーはInfo.plistから省く (欠損の再現)。
    /// `writePlist: false` ならInfo.plist自体を作らない。
    @discardableResult
    private func makeFakeBundle(
        appDirectoryName: String,
        bundleID: String?,
        version: String?,
        writePlist: Bool = true
    ) -> URL {
        let bundleDir = applicationsDirectory.appendingPathComponent(appDirectoryName)
        let contentsDir = bundleDir.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

        if writePlist {
            var plist: [String: Any] = [:]
            if let bundleID { plist["CFBundleIdentifier"] = bundleID }
            if let version { plist["CFBundleShortVersionString"] = version }
            let data = try! PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try! data.write(to: contentsDir.appendingPathComponent("Info.plist"))
        }
        return bundleDir
    }

    /// ディレクトリでない `.app` (通常ファイル) を配置先へ作る (対象判定の棄却ケース)。
    private func makeFakeFile(name: String) {
        try! FileManager.default.createDirectory(
            at: applicationsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: applicationsDirectory.appendingPathComponent(name).path,
            contents: Data("not-a-bundle".utf8))
    }

    private struct Captured {
        var stdout: [String] = []
        var stderr: [String] = []
        var exitCodes: [Int32] = []
    }

    @discardableResult
    private func run(
        json: Bool,
        listDirectory: @escaping (String) throws -> [String] = {
            try FileManager.default.contentsOfDirectory(atPath: $0)
        }
    ) -> Captured {
        var captured = Captured()
        ListCommand.perform(
            json: json,
            homeDirectory: homeDirectory,
            fileManager: .default,
            listDirectory: listDirectory,
            stdoutWriter: { captured.stdout.append($0) },
            stderrWriter: { captured.stderr.append($0) },
            exit: { captured.exitCodes.append($0) }
        )
        return captured
    }

    // MARK: - Parsing

    func testParsesJsonFlag() throws {
        let command = try ListCommand.parse(["--json"])
        XCTAssertTrue(command.json)
    }

    func testParsesWithoutJsonFlagDefaultsToFalse() throws {
        let command = try ListCommand.parse([])
        XCTAssertFalse(command.json)
    }

    // MARK: - Target recognition (adoption / rejection, Requirement 14.7)

    func testTextListsOnlyConventionMatchingBundles() {
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: "com.mjun0812.yobirin", version: "0.2.0")
        makeFakeBundle(
            appDirectoryName: "Yobirin-Claude.app", bundleID: "com.mjun0812.yobirin.claude",
            version: "0.2.0")
        makeFakeBundle(
            appDirectoryName: "Yobirin-My-App.app", bundleID: "com.example.other", version: "1.0.0")
        makeFakeBundle(
            appDirectoryName: "Yobirin-ABC.app", bundleID: "com.example.other2", version: "1.0.0")
        makeFakeBundle(appDirectoryName: "Other.app", bundleID: "com.example.other3", version: "1.0.0")
        makeFakeFile(name: "Yobirin-NotADir.app")

        let captured = run(json: false)

        XCTAssertEqual(captured.stdout.count, 1)
        let output = captured.stdout[0]
        XCTAssertTrue(output.contains("com.mjun0812.yobirin"))
        XCTAssertTrue(output.contains("com.mjun0812.yobirin.claude"))
        XCTAssertFalse(output.contains("com.example.other"))
        XCTAssertTrue(captured.stderr.isEmpty)
        XCTAssertTrue(captured.exitCodes.isEmpty)
    }

    func testJsonListsOnlyConventionMatchingBundles() throws {
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: "com.mjun0812.yobirin", version: "0.2.0")
        makeFakeBundle(
            appDirectoryName: "Yobirin-My-App.app", bundleID: "com.example.other", version: "1.0.0")
        makeFakeBundle(appDirectoryName: "Other.app", bundleID: "com.example.other2", version: "1.0.0")

        let captured = run(json: true)

        XCTAssertEqual(captured.stdout.count, 1)
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let bundles = json["bundles"] as! [[String: Any]]
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0]["bundleID"] as? String, "com.mjun0812.yobirin")
    }

    // MARK: - Default vs profile display (Requirement 14.3)

    func testDefaultBundleShownAsDefaultTextAndNullProfileInJson() throws {
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: "com.mjun0812.yobirin", version: "0.2.0")
        makeFakeBundle(
            appDirectoryName: "Yobirin-Claude.app", bundleID: "com.mjun0812.yobirin.claude",
            version: "0.2.0")

        let textCaptured = run(json: false)
        XCTAssertTrue(textCaptured.stdout[0].contains("(default)"))

        let jsonCaptured = run(json: true)
        let json =
            try JSONSerialization.jsonObject(with: Data(jsonCaptured.stdout[0].utf8)) as! [String: Any]
        let bundles = json["bundles"] as! [[String: Any]]
        let defaultEntry = bundles.first { $0["bundleID"] as? String == "com.mjun0812.yobirin" }!
        XCTAssertTrue(defaultEntry["profile"] is NSNull)
        let claudeEntry = bundles.first { $0["profile"] as? String == "claude" }!
        XCTAssertEqual(claudeEntry["bundleID"] as? String, "com.mjun0812.yobirin.claude")
    }

    // MARK: - Ordering (Requirement 14.4): default first, then profile name ascending

    func testOrdersDefaultFirstThenProfilesAlphabetically() throws {
        // 作成順をあえて逆にして、走査順ではなくソートで並ぶことを確認する。
        makeFakeBundle(
            appDirectoryName: "Yobirin-Codex.app", bundleID: "com.mjun0812.yobirin.codex",
            version: "0.2.0")
        makeFakeBundle(
            appDirectoryName: "Yobirin-Claude.app", bundleID: "com.mjun0812.yobirin.claude",
            version: "0.2.0")
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: "com.mjun0812.yobirin", version: "0.2.0")

        let captured = run(json: true)
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let bundles = json["bundles"] as! [[String: Any]]
        let profiles = bundles.map { $0["profile"] as? String }
        XCTAssertEqual(profiles, [nil, "claude", "codex"])
    }

    // MARK: - Missing fields continue listing (Requirement 14.8)

    func testMissingInfoPlistShowsDashInTextAndNullInJsonAndContinues() throws {
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: nil, version: nil, writePlist: false)
        makeFakeBundle(
            appDirectoryName: "Yobirin-Claude.app", bundleID: "com.mjun0812.yobirin.claude",
            version: "0.2.0")

        let textCaptured = run(json: false)
        let lines = textCaptured.stdout[0].components(separatedBy: "\n")
        let defaultLine = lines.first { $0.contains("(default)") }!
        XCTAssertTrue(defaultLine.contains("-"))
        XCTAssertTrue(textCaptured.stdout[0].contains("com.mjun0812.yobirin.claude"))

        let jsonCaptured = run(json: true)
        let json =
            try JSONSerialization.jsonObject(with: Data(jsonCaptured.stdout[0].utf8)) as! [String: Any]
        let bundles = json["bundles"] as! [[String: Any]]
        let defaultEntry = bundles.first { $0["profile"] is NSNull }!
        XCTAssertTrue(defaultEntry["bundleID"] is NSNull)
        XCTAssertTrue(defaultEntry["version"] is NSNull)
        let claudeEntry = bundles.first { $0["profile"] as? String == "claude" }!
        XCTAssertEqual(claudeEntry["version"] as? String, "0.2.0")
    }

    func testMissingIndividualPlistKeyIsNullWhileOtherKeyRemains() throws {
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: "com.mjun0812.yobirin", version: nil)

        let captured = run(json: true)
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let bundles = json["bundles"] as! [[String: Any]]
        XCTAssertEqual(bundles[0]["bundleID"] as? String, "com.mjun0812.yobirin")
        XCTAssertTrue(bundles[0]["version"] is NSNull)
    }

    // MARK: - Zero entries (Requirement 14.6): missing directory and empty directory are both OK

    func testMissingApplicationsDirectoryIsZeroEntriesAndExitsCleanly() {
        let captured = run(json: false)

        XCTAssertEqual(captured.stdout.count, 1)
        XCTAssertFalse(captured.stdout[0].isEmpty)
        XCTAssertTrue(captured.stderr.isEmpty)
        XCTAssertTrue(captured.exitCodes.isEmpty)
    }

    func testEmptyApplicationsDirectoryIsZeroEntriesAndExitsCleanly() {
        try! FileManager.default.createDirectory(
            at: applicationsDirectory, withIntermediateDirectories: true)

        let captured = run(json: false)

        XCTAssertEqual(captured.stdout.count, 1)
        XCTAssertTrue(captured.stderr.isEmpty)
        XCTAssertTrue(captured.exitCodes.isEmpty)
    }

    func testJsonWithZeroEntriesIsEmptyBundlesArrayWithoutGuidanceText() {
        let captured = run(json: true)

        XCTAssertEqual(captured.stdout, ["{\"bundles\":[]}"])
        XCTAssertTrue(captured.stderr.isEmpty)
        XCTAssertTrue(captured.exitCodes.isEmpty)
    }

    // MARK: - Scan failure (Requirement 14.9): non-zero exit, no stdout

    func testScanFailureWritesStderrAndExitsNonZeroWithoutStdout() {
        try! FileManager.default.createDirectory(
            at: applicationsDirectory, withIntermediateDirectories: true)
        struct ScanError: Error {}

        let captured = run(json: false, listDirectory: { _ in throw ScanError() })

        XCTAssertTrue(captured.stdout.isEmpty)
        XCTAssertEqual(captured.stderr.count, 1)
        XCTAssertEqual(captured.exitCodes, [ResultEmitter.environmentErrorExitCode])
    }

    // MARK: - JSON schema (keys and structure, Requirement 14.5)

    func testJsonSchemaHasExpectedKeys() throws {
        makeFakeBundle(appDirectoryName: "Yobirin.app", bundleID: "com.mjun0812.yobirin", version: "0.2.0")

        let captured = run(json: true)
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let bundles = json["bundles"] as! [[String: Any]]
        let entry = bundles[0]
        XCTAssertEqual(Set(entry.keys), Set(["profile", "bundleID", "version", "path"]))
        XCTAssertEqual(
            entry["path"] as? String,
            applicationsDirectory.appendingPathComponent("Yobirin.app").path)
    }
}
