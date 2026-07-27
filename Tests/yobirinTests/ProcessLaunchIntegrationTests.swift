import Foundation
import XCTest

@testable import yobirin

/// 実際にビルドされたバイナリを `Process` で起動する結合テスト
/// (design.md Testing Strategy > Integration Tests、起動ゲートとインストールのフロー、
/// Requirements 11.6, 11.9, 12.1)。
///
/// `LaunchGateTests` / `InstallerTests` / `InstallCommandTests` は注入したfakeで純粋関数・
/// ロジックを検証済みだが、それらは「実際にビルドされたバイナリをプロセスとして起動したときに
/// 同じ結線が機能するか」(ArgumentParserの実際の `--help` 処理、`_NSGetExecutablePath` による
/// 実行パス解決、`Installer.install` の既定引数 (`NSHomeDirectory()` 等) を経由した実配線) までは
/// 検証しない。本ファイルはその結合レベルの検証を担う。
///
/// ## 対象外にした範囲とその理由
///
/// - バンドル内の起動マトリクス (通知系 / 引数なしの孤児掃除): 実際の `.app` バンドル・
///   通知許可 (GUI) が必要なため自動テストできない (design.md「通知の表示・対話・権限フローは
///   自動テストできない」)。8.2 実機確認・9.2 手動検証チェックリストでカバーする。
///   バンドル内マトリクスの分岐ロジック自体は `LaunchGateTests` が純粋関数として検証済み。
/// - install の非symlink実ファイル衝突・成功系を実プロセスで再現すること: `Installer.install` の
///   `homeDirectory` 引数は task 13.1 以降 `ProfileNaming.resolvedHomeDirectory()`
///   (`YOBIRIN_HOME` 環境変数、未設定時は `NSHomeDirectory()`) を既定値とし、
///   `environmentWithTemporaryHome` で渡す `YOBIRIN_HOME` によりテンポラリ領域へ密閉できるように
///   なった (以前は `HOME` を差し替えても `NSHomeDirectory()` の戻り値が変わらず密閉不能だった)。
///   ただしこの2ケースの実プロセス再現追加は本タスクの主眼 (ホーム解決の一元化とゲート判定拡張)
///   の範囲外のため見送り、引き続き `InstallerTests` (fake注入によるテンポラリ領域での検証。
///   `testInstallFailsWhenExistingBinPathIsNonSymlinkFileAndLeavesItUntouched` /
///   `testInstallCreatesSymlinkPointingToInstalledMachO` 等) のカバレッジに委ねる。
/// - 署名失敗 (Requirement 11.6) を実プロセスで再現すること: 実 `codesign` を意図的に失敗させる
///   決定的な方法がなく、既に `InstallerTests.testInstallFailsWhenCodesignSigningFails` (fake
///   `runProcess` 注入) でカバー済みのため新規に無理な再現はしない。
final class ProcessLaunchIntegrationTests: XCTestCase {
    // MARK: - ビルド済みバイナリの場所 (SwiftPM標準の手法)

    /// xctestバンドルと同じディレクトリ (products directory) に `yobirin` 実行ファイルが
    /// 存在する。`swift test` は依存先のexecutableTargetも同じ場所へビルドするため成立する。
    private static let productsDirectory: URL = {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("products directory (xctestバンドルの隣) が見つかりません")
    }()

    private static let yobirinExecutablePath =
        productsDirectory.appendingPathComponent("yobirin").path

    // MARK: - プロセス起動ヘルパ

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// バイナリをプロセスとして起動し、終了コード・stdout・stderrを収集する。
    /// パイプの相互デッドロックを避けるため、出力はテンポラリファイルへリダイレクトしてから
    /// 終了後にまとめて読み戻す (パイプのバッファ枯渇による待機は本テストの出力量では起きない
    /// が、ファイル経由なら構造的に発生しない)。
    private func runYobirin(
        executablePath: String? = nil,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath ?? Self.yobirinExecutablePath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-process-test-stdout-\(UUID().uuidString)")
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-process-test-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        try process.run()
        process.waitUntilExit()

        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "")
    }

    /// installを実プロセスで起動する際に使う環境。`HOME` / `YOBIRIN_BIN_DIR` に加え、task 13.1で
    /// ホーム解決の単一ソースとなった `YOBIRIN_HOME` もテンポラリ領域へ差し替える (実
    /// `~/Applications` ・実 `~/.local/bin` を汚さないための防御的な措置)。`NSHomeDirectory()` は
    /// 子プロセスの `HOME` を反映しないため、依然として `HOME` 単体では密閉できない
    /// (`getenv("HOME")` は差し替わるが `NSHomeDirectory()` は実ユーザーの実ホームを返し続ける) が、
    /// `Installer.install` の `homeDirectory` 既定値は `ProfileNaming.resolvedHomeDirectory()`
    /// 経由で `YOBIRIN_HOME` を直接読むため、この変数を渡す限り密閉が効く。
    private func environmentWithTemporaryHome(homeDirectory: String, binDirectory: String)
        -> [String: String]
    {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory
        environment[ProfileNaming.homeEnvironmentKey] = homeDirectory
        environment[Installer.binDirectoryEnvironmentKey] = binDirectory
        return environment
    }

    /// `list` / `ps` / 起動ゲートの実プロセステストへ `YOBIRIN_HOME` を渡し、実マシンの
    /// インストール状態 (実 `~/Applications` の内容) から独立させる (design.md 起動ゲート
    /// 「結合テストはこの変数でバンドル探索・配置先をテンポラリ領域へ密閉する」、task 13.1)。
    /// 参照先ディレクトリは作成しない (`list`/`ps` は不存在を0件として扱い、起動ゲートは
    /// デフォルトバンドル未インストールとして扱う)。
    private func environmentWithIsolatedYobirinHome() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[ProfileNaming.homeEnvironmentKey] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-isolated-home-\(UUID().uuidString)").path
        return environment
    }

    // MARK: - A. 起動ゲートの結合マトリクス (バンドル外、実プロセス起動)
    // (Requirements 12.1, 12.2, 12.3)

    func testOutsideBundleWithNoArgumentsGuidesInstallAndExitsNonZero() throws {
        // YOBIRIN_HOMEを空のテンポラリ領域へ密閉し、実マシンにデフォルトバンドルが導入済みで
        // あっても「未インストール」として振る舞うことを保証する (task 13.1: 現状mainの
        // バンドル存在判定は固定falseのため今はYOBIRIN_HOMEの値自体は無関係だが、task 13.2で
        // 実配線されたあとも本テストが実マシンの状態に左右されないようにする)。
        let result = try runYobirin(
            arguments: [], environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("yobirin install"))
    }

    func testOutsideBundleWithNotificationArgumentsGuidesInstallAndExitsNonZero() throws {
        let result = try runYobirin(
            arguments: ["--title", "t", "--message", "m"],
            environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("yobirin install"))
    }

    func testOutsideBundleWithInstallHelpCompletesWithoutTouchingNotificationAPI() throws {
        // Requirement 12.1: インストール系のサブコマンドは通知機能に依存せずに完了する。
        // `--help` はArgumentParserが `InstallCommand.run()` を呼ぶ前に処理するため、
        // 通知APIの型には一切触れず完走することを実プロセスで確認する。
        let result = try runYobirin(arguments: ["install", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Assemble and install Yobirin.app"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testOutsideBundleWithHelpExitsZero() throws {
        let result = try runYobirin(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testOutsideBundleWithVersionPrintsVersionAndExitsZero() throws {
        // 起動ゲートが `--version` をrunCLIへ通し、ArgumentParser側でも
        // `CommandConfiguration.version` (YobirinVersion.current) が結線されていることを
        // 実プロセスで確認する (どちらか片方だけだとusageエラーになる)。
        let result = try runYobirin(arguments: ["--version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            YobirinVersion.current)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    // MARK: - A. list (バンドル外、実プロセス起動)
    // (Requirements 14.1, 14.5, 14.10。実ホームの内容に依存する項目の有無はここでは検証せず、
    // 「通知APIに触れずクラッシュなく完走する」ことをexit 0・stderr空・出力形状のみで確認する。)

    func testOutsideBundleWithListCompletesWithoutTouchingNotificationAPI() throws {
        let result = try runYobirin(
            arguments: ["list"], environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testOutsideBundleWithListJSONCompletesWithoutTouchingNotificationAPI() throws {
        let result = try runYobirin(
            arguments: ["list", "--json"], environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertTrue(result.stdout.hasPrefix("{\"bundles\":"))
    }

    // MARK: - A. ps (バンドル外、実プロセス起動)
    // (Requirements 15.1, 15.5, 15.9。実環境の待機プロセスの有無・内容には依存せず、
    // 「通知APIに触れずクラッシュなく完走する」ことをexit 0・stderr空・出力形状のみで確認する。)

    func testOutsideBundleWithPsCompletesWithoutTouchingNotificationAPI() throws {
        let result = try runYobirin(
            arguments: ["ps"], environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testOutsideBundleWithPsJSONCompletesWithoutTouchingNotificationAPI() throws {
        let result = try runYobirin(
            arguments: ["ps", "--json"], environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertTrue(result.stdout.hasPrefix("{\"processes\":"))
    }

    // MARK: - A. symlink経由起動 (実体パスへの再exec。design.md CLIとアプリの二面性)

    func testSymlinkToPlainBinaryReExecsAndStillGuidesInstallWithoutRecursion() throws {
        // symlink先が素のバイナリの場合、`BundleEnvironment.reExecThroughSymlinkIfNeeded` が
        // 実体パスへ再execする。再exec後は実行パス==realpathとなるため再帰は起きず、素の
        // バイナリと同じ「案内 + exit 1」に到達する。再帰していればハングするはずだが、
        // ここでは特別なタイムアウト処理を入れず、プロセスが素直に終了することそのもので
        // 再帰しないことを確認する。
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-symlink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let linkPath = tempDir.appendingPathComponent("yobirin").path
        try FileManager.default.createSymbolicLink(
            atPath: linkPath, withDestinationPath: Self.yobirinExecutablePath)

        let result = try runYobirin(
            executablePath: linkPath, arguments: [],
            environment: environmentWithIsolatedYobirinHome())

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("yobirin install"))
    }

    // MARK: - B. installの失敗系 (実プロセス起動)
    // (Requirement 11.6 の署名失敗はInstallerTestsのfakeでカバー済み。本ファイルでは
    // 実プロセス起動でも安全に再現できるアイコン不在のケースのみを扱う。)

    func testInstallOutsideBundleFailsWithNonZeroAndStderrWhenIconPathDoesNotExist() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-install-process-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let missingIconPath = tempRoot.appendingPathComponent("missing-icon.png").path

        let result = try runYobirin(
            arguments: ["install", "--icon", missingIconPath],
            environment: environmentWithTemporaryHome(
                homeDirectory: tempRoot.appendingPathComponent("home").path,
                binDirectory: tempRoot.appendingPathComponent("bin").path))

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains(missingIconPath))
        // アイコン読込 (Installer.install の手順3) はステージング領域 (システムの一時ディレクトリ)
        // で完結し、`homeDirectory` に依存する配置処理 (手順5) より前に例外を投げるため、
        // 実 `~/Applications` には到達しない。
    }
}
