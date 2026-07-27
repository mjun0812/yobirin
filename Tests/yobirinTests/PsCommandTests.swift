import Foundation
import XCTest

@testable import yobirin

/// `ps` サブコマンド (`PsCommand`) のテスト (design.md PsCommand・psJSON契約、Requirements
/// 15.1〜15.8)。
///
/// fakeレコード (`PsCommand.RawProcessRecord`) を `scan` クロージャで注入して検証する。実
/// プロセスの走査には一切触れない (走査は読み取り専用の別クロージャに閉じ込められている)。
final class PsCommandTests: XCTestCase {
    private let homeDirectory = "/Users/fake"
    private let currentPID: Int32 = 999
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private var defaultMachOPath: String {
        ProfileNaming.default(homeDirectory: homeDirectory).machOPath
    }

    private func profileMachOPath(_ name: String) throws -> String {
        try ProfileNaming.forProfile(name, homeDirectory: homeDirectory).machOPath
    }

    private struct Captured {
        var stdout: [String] = []
        var stderr: [String] = []
        var exitCodes: [Int32] = []
    }

    @discardableResult
    private func run(
        json: Bool,
        currentPID: Int32? = nil,
        now: Date? = nil,
        scan: @escaping () throws -> [PsCommand.RawProcessRecord]
    ) -> Captured {
        var captured = Captured()
        PsCommand.perform(
            json: json,
            currentPID: currentPID ?? self.currentPID,
            now: now ?? self.now,
            homeDirectory: homeDirectory,
            scan: scan,
            stdoutWriter: { captured.stdout.append($0) },
            stderrWriter: { captured.stderr.append($0) },
            exit: { captured.exitCodes.append($0) }
        )
        return captured
    }

    private func record(
        pid: Int32,
        path: String,
        argv: [String]?,
        startTime: Date
    ) -> PsCommand.RawProcessRecord {
        PsCommand.RawProcessRecord(pid: pid, path: path, argv: argv, startTime: startTime)
    }

    // MARK: - Parsing

    func testParsesJsonFlag() throws {
        let command = try PsCommand.parse(["--json"])
        XCTAssertTrue(command.json)
    }

    func testParsesWithoutJsonFlagDefaultsToFalse() throws {
        let command = try PsCommand.parse([])
        XCTAssertFalse(command.json)
    }

    // MARK: - Target recognition: adoption (Requirement 15.2)

    func testAdoptsDefaultBundleProcessWithTitleArgv() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 100, path: self.defaultMachOPath,
                    argv: ["yobirin", "--title", "ビルド完了", "--message", "OK"],
                    startTime: self.now.addingTimeInterval(-42))
            ]
        }

        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0]["pid"] as? Int, 100)
        XCTAssertTrue(processes[0]["profile"] is NSNull)
        XCTAssertEqual(processes[0]["title"] as? String, "ビルド完了")
    }

    func testAdoptsProfileBundleProcessWithTitleArgv() throws {
        let path = try profileMachOPath("claude")
        let captured = run(json: true) {
            [
                self.record(
                    pid: 101, path: path, argv: ["yobirin", "--title", "確認"],
                    startTime: self.now.addingTimeInterval(-5))
            ]
        }

        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0]["profile"] as? String, "claude")
    }

    // MARK: - Target recognition: rejection (Requirement 15.2)

    func testExcludesInstallLikeArgvWithoutTitleFlag() {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 102, path: self.defaultMachOPath, argv: ["yobirin", "install"],
                    startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesListLikeArgvWithoutTitleFlag() {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 103, path: self.defaultMachOPath, argv: ["yobirin", "list", "--json"],
                    startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesPsLikeArgvWithoutTitleFlag() {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 104, path: self.defaultMachOPath, argv: ["yobirin", "ps"], startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesArgumentlessSweepArgv() {
        let captured = run(json: true) {
            [
                self.record(pid: 105, path: self.defaultMachOPath, argv: ["yobirin"], startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesCurrentPIDEvenWithTitleArgv() {
        let captured = run(json: true) {
            [
                self.record(
                    pid: self.currentPID, path: self.defaultMachOPath,
                    argv: ["yobirin", "--title", "x"], startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesNonConventionPathEvenWithTitleArgv() {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 106, path: "/Users/fake/repo/.build/release/yobirin",
                    argv: ["yobirin", "--title", "x"], startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesConventionRejectingAppNameEvenWithTitleArgv() {
        let path = "\(homeDirectory)/Applications/Yobirin-My-App.app/Contents/MacOS/yobirin"
        let captured = run(json: true) {
            [
                self.record(pid: 107, path: path, argv: ["yobirin", "--title", "x"], startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    func testExcludesMismatchedCapitalizationEvenWithTitleArgv() {
        // 順方向導出 (Yobirin-Abc) と一致しないディレクトリ名 (Yobirin-ABC) は往復一致で棄却される。
        let path = "\(homeDirectory)/Applications/Yobirin-ABC.app/Contents/MacOS/yobirin"
        let captured = run(json: true) {
            [
                self.record(pid: 108, path: path, argv: ["yobirin", "--title", "x"], startTime: self.now)
            ]
        }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
    }

    // MARK: - Default vs profile display (Requirement 15.3)

    func testDefaultShownAsDefaultTextAndNullProfileInJson() throws {
        let textCaptured = run(json: false) {
            [
                self.record(
                    pid: 200, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now)
            ]
        }
        XCTAssertTrue(textCaptured.stdout[0].contains("(default)"))

        let jsonCaptured = run(json: true) {
            [
                self.record(
                    pid: 200, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now)
            ]
        }
        let json =
            try JSONSerialization.jsonObject(with: Data(jsonCaptured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertTrue(processes[0]["profile"] is NSNull)
    }

    // MARK: - Title / timeout extraction (Requirement 15.3)

    func testExtractsTitleWithSpaceForm() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 300, path: self.defaultMachOPath, argv: ["yobirin", "--title", "スペース形式"],
                    startTime: self.now)
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes[0]["title"] as? String, "スペース形式")
    }

    func testExtractsTitleWithEqualsForm() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 301, path: self.defaultMachOPath, argv: ["yobirin", "--title=イコール形式"],
                    startTime: self.now)
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes[0]["title"] as? String, "イコール形式")
    }

    func testExtractsTimeoutWithSpaceForm() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 302, path: self.defaultMachOPath,
                    argv: ["yobirin", "--title", "t", "--timeout", "300"], startTime: self.now)
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes[0]["timeoutSeconds"] as? Int, 300)
    }

    func testExtractsTimeoutWithEqualsForm() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 303, path: self.defaultMachOPath,
                    argv: ["yobirin", "--title=t", "--timeout=45"], startTime: self.now)
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes[0]["timeoutSeconds"] as? Int, 45)
    }

    func testMissingTimeoutIsDashInTextAndNullInJson() throws {
        let textCaptured = run(json: false) {
            [
                self.record(
                    pid: 304, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now)
            ]
        }
        XCTAssertTrue(textCaptured.stdout[0].contains("-"))

        let jsonCaptured = run(json: true) {
            [
                self.record(
                    pid: 304, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now)
            ]
        }
        let json =
            try JSONSerialization.jsonObject(with: Data(jsonCaptured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertTrue(processes[0]["timeoutSeconds"] is NSNull)
    }

    // MARK: - Missing argv continues listing (Requirement 15.7)

    func testMissingArgvShowsDashInTextAndNullInJsonAndContinues() throws {
        let textCaptured = run(json: false) {
            [
                self.record(pid: 400, path: self.defaultMachOPath, argv: nil, startTime: self.now)
            ]
        }
        let lines = textCaptured.stdout[0].components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("-"))

        let jsonCaptured = run(json: true) {
            [
                self.record(pid: 400, path: self.defaultMachOPath, argv: nil, startTime: self.now)
            ]
        }
        let json =
            try JSONSerialization.jsonObject(with: Data(jsonCaptured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes.count, 1)
        XCTAssertTrue(processes[0]["title"] is NSNull)
        XCTAssertTrue(processes[0]["timeoutSeconds"] is NSNull)
    }

    func testMissingArgvProcessDoesNotBlockOtherEntries() throws {
        let captured = run(json: true) {
            [
                self.record(pid: 401, path: self.defaultMachOPath, argv: nil, startTime: self.now),
                self.record(
                    pid: 402, path: self.defaultMachOPath, argv: ["yobirin", "--title", "残り"],
                    startTime: self.now.addingTimeInterval(1)),
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes.count, 2)
    }

    // MARK: - Ordering (Requirement 15.4): startTime ascending, PID tie-break ascending

    func testOrdersByStartTimeAscending() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 500, path: self.defaultMachOPath, argv: ["yobirin", "--title", "new"],
                    startTime: self.now.addingTimeInterval(-1)),
                self.record(
                    pid: 501, path: self.defaultMachOPath, argv: ["yobirin", "--title", "old"],
                    startTime: self.now.addingTimeInterval(-100)),
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        let pids = processes.map { $0["pid"] as! Int }
        XCTAssertEqual(pids, [501, 500])
    }

    func testTiebreaksBySamestartTimeByPIDAscending() throws {
        let sameStartTime = now.addingTimeInterval(-10)
        let captured = run(json: true) {
            [
                self.record(
                    pid: 602, path: self.defaultMachOPath, argv: ["yobirin", "--title", "b"],
                    startTime: sameStartTime),
                self.record(
                    pid: 601, path: self.defaultMachOPath, argv: ["yobirin", "--title", "a"],
                    startTime: sameStartTime),
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        let pids = processes.map { $0["pid"] as! Int }
        XCTAssertEqual(pids, [601, 602])
    }

    // MARK: - Zero entries (Requirement 15.6)

    func testZeroProcessesShowsGuidanceTextAndExitsCleanly() {
        let captured = run(json: false) { [] }
        XCTAssertEqual(captured.stdout.count, 1)
        XCTAssertFalse(captured.stdout[0].isEmpty)
        XCTAssertTrue(captured.stderr.isEmpty)
        XCTAssertTrue(captured.exitCodes.isEmpty)
    }

    func testZeroProcessesJsonIsEmptyArrayAndExitsCleanly() {
        let captured = run(json: true) { [] }
        XCTAssertEqual(captured.stdout, ["{\"processes\":[]}"])
        XCTAssertTrue(captured.stderr.isEmpty)
        XCTAssertTrue(captured.exitCodes.isEmpty)
    }

    // MARK: - Scan failure (Requirement 15.8): non-zero exit, no stdout

    func testScanFailureWritesStderrAndExitsNonZeroWithoutStdout() {
        struct ScanError: Error {}
        let captured = run(json: false) { throw ScanError() }

        XCTAssertTrue(captured.stdout.isEmpty)
        XCTAssertEqual(captured.stderr.count, 1)
        XCTAssertEqual(captured.exitCodes, [ResultEmitter.environmentErrorExitCode])
    }

    // MARK: - Elapsed time formatting boundaries

    func testElapsedFormatsSecondsUnderOneMinute() throws {
        let captured = run(json: false, now: now) {
            [
                self.record(
                    pid: 700, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now.addingTimeInterval(-59))
            ]
        }
        XCTAssertTrue(captured.stdout[0].contains("59s"))
    }

    func testElapsedFormatsExactlyOneMinuteBoundary() throws {
        let captured = run(json: false, now: now) {
            [
                self.record(
                    pid: 701, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now.addingTimeInterval(-60))
            ]
        }
        XCTAssertTrue(captured.stdout[0].contains("1m00s"))
    }

    func testElapsedFormatsMinutesAndSeconds() throws {
        let captured = run(json: false, now: now) {
            [
                self.record(
                    pid: 702, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now.addingTimeInterval(-(12 * 60 + 34)))
            ]
        }
        XCTAssertTrue(captured.stdout[0].contains("12m34s"))
    }

    func testElapsedFormatsExactlyOneHourBoundary() throws {
        let captured = run(json: false, now: now) {
            [
                self.record(
                    pid: 703, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now.addingTimeInterval(-3600))
            ]
        }
        XCTAssertTrue(captured.stdout[0].contains("1h00m"))
    }

    func testElapsedFormatsHoursAndMinutes() throws {
        let captured = run(json: false, now: now) {
            [
                self.record(
                    pid: 704, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now.addingTimeInterval(-(3600 + 2 * 60)))
            ]
        }
        XCTAssertTrue(captured.stdout[0].contains("1h02m"))
    }

    func testElapsedSecondsInJsonIsRawSecondsNotFormatted() throws {
        let captured = run(json: true, now: now) {
            [
                self.record(
                    pid: 705, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now.addingTimeInterval(-90))
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        XCTAssertEqual(processes[0]["elapsedSeconds"] as? Int, 90)
    }

    // MARK: - JSON schema (keys and structure, Requirement 15.5)

    func testJsonSchemaHasExpectedKeys() throws {
        let captured = run(json: true) {
            [
                self.record(
                    pid: 800, path: self.defaultMachOPath, argv: ["yobirin", "--title", "t"],
                    startTime: self.now)
            ]
        }
        let json = try JSONSerialization.jsonObject(with: Data(captured.stdout[0].utf8)) as! [String: Any]
        let processes = json["processes"] as! [[String: Any]]
        let entry = processes[0]
        XCTAssertEqual(
            Set(entry.keys),
            Set(["pid", "profile", "title", "timeoutSeconds", "elapsedSeconds", "path"]))
        XCTAssertEqual(entry["path"] as? String, defaultMachOPath)
    }
}
