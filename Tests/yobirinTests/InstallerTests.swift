import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import yobirin

/// インストーラ本体 (`Installer`) のテスト
/// (design.md Build / Distribution > Installer / IcnsWriter / DefaultIcon、
/// Requirements 8.4, 8.5, 9.4, 11.1, 11.2, 11.3, 11.5, 11.6, 11.7, 11.9, 12.1)。
///
/// 実codesign・実 `~/Applications` への配置はテストで行わない (8.1/8.2の範囲)。
/// テンポラリ領域のみを使い、自己バイナリ解決・外部プロセス実行はすべて注入する。
final class InstallerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-installer-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    private var homeDirectory: String { tempRoot.appendingPathComponent("home").path }
    private var binDirectory: String { tempRoot.appendingPathComponent("bin").path }

    /// テスト用のダミー自己バイナリ (中身は任意のマーカーバイト列)。実行はしない。
    private func makeDummySelfExecutable(content: Data = Data("dummy-yobirin-binary".utf8)) -> String {
        let path = tempRoot.appendingPathComponent("self-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: content)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// 4x4の単色PNGをテスト用の元画像として生成する
    /// (IcnsWriterはImageIOでデコード可能な実PNGを要求するため、マジックバイトだけでは不十分)。
    private func makeTestPNGData() -> Data {
        let size = 4
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 常に0を返す (成功) runProcessのスタブ。呼び出しを記録する。
    private func makeAlwaysSucceedingRunProcess() -> (
        run: Installer.ProcessRunner, calls: () -> [(String, [String])]
    ) {
        var calls: [(String, [String])] = []
        let run: Installer.ProcessRunner = { path, arguments in
            calls.append((path, arguments))
            return 0
        }
        return (run, { calls })
    }

    // MARK: - 組み立て内容 (Requirements 11.2, 11.3, 8.4)

    func testInstallAssemblesBundleWithSelfBinaryInfoPlistAndIcon() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        let bundlePath = "\(homeDirectory)/Applications/Yobirin.app"
        let executablePath = "\(bundlePath)/Contents/MacOS/yobirin"
        XCTAssertEqual(
            FileManager.default.contents(atPath: executablePath),
            FileManager.default.contents(atPath: selfPath))

        let plistData = try Data(contentsOf: URL(fileURLWithPath: "\(bundlePath)/Contents/Info.plist"))
        let plist =
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.mjun0812.yobirin")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Yobirin")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "yobirin")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, YobirinVersion.current)
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "\(bundlePath)/Contents/Resources/AppIcon.icns"))
    }

    func testInstallUsesProvidedIconPathInsteadOfDefault() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let iconPath = tempRoot.appendingPathComponent("custom-icon.png").path
        FileManager.default.createFile(atPath: iconPath, contents: makeTestPNGData())
        var defaultIconCallCount = 0

        try Installer.install(
            profile: nil,
            iconPath: iconPath,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            defaultIconData: {
                defaultIconCallCount += 1
                return Data()
            },
            runProcess: runProcess
        )

        XCTAssertEqual(defaultIconCallCount, 0)
    }

    func testInstallWithoutIconPathUsesDefaultIconData() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        var defaultIconCallCount = 0

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            defaultIconData: {
                defaultIconCallCount += 1
                return DefaultIcon.pngData
            },
            runProcess: runProcess
        )

        XCTAssertEqual(defaultIconCallCount, 1)
    }

    func testInstallFailsWhenIconPathDoesNotExist() {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let missingIconPath = tempRoot.appendingPathComponent("missing.png").path

        XCTAssertThrowsError(
            try Installer.install(
                profile: nil,
                iconPath: missingIconPath,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                resolveSelfExecutablePath: { selfPath },
                runProcess: runProcess
            )
        ) { error in
            XCTAssertEqual(
                error as? Installer.InstallError, .iconUnreadable(path: missingIconPath))
        }
    }

    func testInstallFailsWhenSelfExecutableUnresolvable() {
        let (runProcess, calls) = makeAlwaysSucceedingRunProcess()

        XCTAssertThrowsError(
            try Installer.install(
                profile: nil,
                iconPath: nil,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                resolveSelfExecutablePath: { nil },
                runProcess: runProcess
            )
        ) { error in
            XCTAssertEqual(error as? Installer.InstallError, .selfExecutableUnresolvable)
        }
        XCTAssertTrue(calls().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(homeDirectory)/Applications/Yobirin.app"))
    }

    // MARK: - 署名 (Requirement 11.6)

    func testInstallFailsWhenCodesignSigningFails() {
        let selfPath = makeDummySelfExecutable()
        var calls: [(String, [String])] = []
        let runProcess: Installer.ProcessRunner = { path, arguments in
            calls.append((path, arguments))
            return arguments.contains("--sign") ? 1 : 0
        }

        XCTAssertThrowsError(
            try Installer.install(
                profile: nil,
                iconPath: nil,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                resolveSelfExecutablePath: { selfPath },
                runProcess: runProcess
            )
        ) { error in
            XCTAssertEqual(error as? Installer.InstallError, .codesignFailed(exitCode: 1))
        }
        // 署名失敗時点で配置には進んでいない。
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(homeDirectory)/Applications/Yobirin.app"))
    }

    // MARK: - 配置 (Requirements 8.4, 8.5, 11.5)

    func testInstallReplacesOldBundleBeforeCopyingNew() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let oldBundlePath = "\(homeDirectory)/Applications/Yobirin.app"
        let oldMarkerPath = "\(oldBundlePath)/Contents/Resources/OLD_MARKER"
        try FileManager.default.createDirectory(
            atPath: "\(oldBundlePath)/Contents/Resources", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: oldMarkerPath, contents: Data("old".utf8))

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMarkerPath))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "\(oldBundlePath)/Contents/Info.plist"))
    }

    func testInstallCreatesSymlinkPointingToInstalledMachO() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        let linkPath = "\(binDirectory)/yobirin"
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
            "\(homeDirectory)/Applications/Yobirin.app/Contents/MacOS/yobirin")
    }

    func testInstallReplacesExistingSymlinkOnUpgrade() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true)
        let linkPath = "\(binDirectory)/yobirin"
        try FileManager.default.createSymbolicLink(
            atPath: linkPath, withDestinationPath: "/somewhere/else")

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
            "\(homeDirectory)/Applications/Yobirin.app/Contents/MacOS/yobirin")
    }

    func testInstallFailsWhenExistingBinPathIsNonSymlinkFileAndLeavesItUntouched() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true)
        let linkPath = "\(binDirectory)/yobirin"
        let originalContent = Data("not-a-symlink".utf8)
        FileManager.default.createFile(atPath: linkPath, contents: originalContent)

        XCTAssertThrowsError(
            try Installer.install(
                profile: nil,
                iconPath: nil,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                resolveSelfExecutablePath: { selfPath },
                runProcess: runProcess
            )
        ) { error in
            XCTAssertEqual(
                error as? Installer.InstallError, .existingLinkIsNotSymlink(path: linkPath))
        }

        // 非破壊: 既存の実ファイルはそのまま残る。
        XCTAssertEqual(FileManager.default.contents(atPath: linkPath), originalContent)
    }

    func testInstallWithProfileDoesNotTouchDefaultSymlink() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        try Installer.install(
            profile: "claude",
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: "\(homeDirectory)/Applications/Yobirin-Claude.app/Contents/MacOS/yobirin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(binDirectory)/yobirin"))
    }

    func testInstallWithProfileUsesScopedBundleIdentifierAndName() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        try Installer.install(
            profile: "claude",
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        let bundlePath = "\(homeDirectory)/Applications/Yobirin-Claude.app"
        let plistData = try Data(contentsOf: URL(fileURLWithPath: "\(bundlePath)/Contents/Info.plist"))
        let plist =
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.mjun0812.yobirin.claude")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Yobirin-Claude")
    }

    // MARK: - 検証 (Requirement 11.9)

    func testInstallFailsWhenSignatureVerificationFails() {
        let selfPath = makeDummySelfExecutable()
        var calls: [(String, [String])] = []
        let runProcess: Installer.ProcessRunner = { path, arguments in
            calls.append((path, arguments))
            return arguments.contains("--verify") ? 1 : 0
        }

        XCTAssertThrowsError(
            try Installer.install(
                profile: nil,
                iconPath: nil,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                resolveSelfExecutablePath: { selfPath },
                runProcess: runProcess
            )
        ) { error in
            guard case .verificationFailed = error as? Installer.InstallError else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        }
    }

    func testInstallFailsWhenInstalledCommandHelpCheckFails() {
        let selfPath = makeDummySelfExecutable()
        var calls: [(String, [String])] = []
        let runProcess: Installer.ProcessRunner = { path, arguments in
            calls.append((path, arguments))
            if arguments == ["--help"] {
                return 1
            }
            return 0
        }

        XCTAssertThrowsError(
            try Installer.install(
                profile: nil,
                iconPath: nil,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                resolveSelfExecutablePath: { selfPath },
                runProcess: runProcess
            )
        ) { error in
            guard case .verificationFailed = error as? Installer.InstallError else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        }
    }

    func testInstallRunsVerificationAgainstInstalledBundleAndMachO() throws {
        let selfPath = makeDummySelfExecutable()
        var calls: [(String, [String])] = []
        let runProcess: Installer.ProcessRunner = { path, arguments in
            calls.append((path, arguments))
            return 0
        }

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        let bundlePath = "\(homeDirectory)/Applications/Yobirin.app"
        let machOPath = "\(bundlePath)/Contents/MacOS/yobirin"
        XCTAssertTrue(
            calls.contains { $0.0 == "/usr/bin/codesign" && $0.1 == ["--force", "--sign", "-", bundlePath] }
                == false)  // 署名はステージング領域に対して行う (配置前)
        XCTAssertTrue(
            calls.contains {
                $0.0 == "/usr/bin/codesign" && $0.1 == ["--verify", "--deep", "--strict", bundlePath]
            })
        XCTAssertTrue(calls.contains { $0.0 == machOPath && $0.1 == ["--help"] })
    }

    // MARK: - アイコン変化の検出 (Requirement 16)

    func testInstallReturnsNotReplacedForFreshInstall() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let outcome = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertFalse(outcome.replacedExistingBundle)
        XCTAssertFalse(outcome.iconChanged)
    }

    func testInstallReturnsReplacedWithIconUnchangedWhenSameIconReinstalled() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let iconPath = tempRoot.appendingPathComponent("same-icon.png").path
        FileManager.default.createFile(atPath: iconPath, contents: makeTestPNGData())

        _ = try Installer.install(
            profile: nil,
            iconPath: iconPath,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        let outcome = try Installer.install(
            profile: nil,
            iconPath: iconPath,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertTrue(outcome.replacedExistingBundle)
        XCTAssertFalse(outcome.iconChanged)
    }

    func testInstallReturnsReplacedWithIconChangedWhenDifferentIconReinstalled() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        _ = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        let differentIconPath = tempRoot.appendingPathComponent("different-icon.png").path
        FileManager.default.createFile(atPath: differentIconPath, contents: makeTestPNGData())

        let outcome = try Installer.install(
            profile: nil,
            iconPath: differentIconPath,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertTrue(outcome.replacedExistingBundle)
        XCTAssertTrue(outcome.iconChanged)
    }

    func testInstallReturnsIconChangedWhenOldIconUnreadable() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        // 旧バンドルはあるがAppIcon.icnsがない = 旧アイコンが読み取れない状態を再現する (16.4)。
        let bundlePath = "\(homeDirectory)/Applications/Yobirin.app"
        try FileManager.default.createDirectory(
            atPath: "\(bundlePath)/Contents/Resources", withIntermediateDirectories: true)

        let outcome = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertTrue(outcome.replacedExistingBundle)
        XCTAssertTrue(outcome.iconChanged)
    }

    // MARK: - BIN_DIR環境変数 (design.md Install layout)

    func testInstallUsesBinDirectoryEnvironmentVariableWhenNotExplicitlyProvided() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let previous = ProcessInfo.processInfo.environment[Installer.binDirectoryEnvironmentKey]
        setenv(Installer.binDirectoryEnvironmentKey, binDirectory, 1)
        defer {
            if let previous {
                setenv(Installer.binDirectoryEnvironmentKey, previous, 1)
            } else {
                unsetenv(Installer.binDirectoryEnvironmentKey)
            }
        }

        try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: nil,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(binDirectory)/yobirin"))
    }

    // MARK: - Confirmation notification on a fresh install (Requirement 20)

    /// 「起動するだけで待たない」注入点のスタブ。呼び出しを記録し、起動可否を切り替えられる。
    private func makeLauncher(succeeds: Bool = true) -> (
        launch: Installer.DetachedProcessLauncher, calls: () -> [(String, [String])]
    ) {
        var calls: [(String, [String])] = []
        let launch: Installer.DetachedProcessLauncher = { path, arguments in
            calls.append((path, arguments))
            return succeeds
        }
        return (launch, { calls })
    }

    /// 既にインストール済みの状態を作ってから上書きインストールするためのヘルパー。
    private func installOnce(runProcess: @escaping Installer.ProcessRunner, selfPath: String) throws {
        _ = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: { _, _ in true }
        )
    }

    func testFreshInstallLaunchesConfirmationNotificationFromTheInstalledBundle() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let (launch, launchCalls) = makeLauncher()

        let outcome = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: launch
        )

        let naming = try ProfileNaming.resolve(profile: nil, homeDirectory: homeDirectory)
        XCTAssertEqual(launchCalls().count, 1)
        XCTAssertEqual(launchCalls().first?.0, naming.machOPath)
        XCTAssertTrue(outcome.sentConfirmationNotification)
    }

    /// 通知には正のタイムアウトが必須 (20.6: 応答がなくても通知センターに残らない)。
    func testConfirmationNotificationCarriesTitleMessageAndPositiveTimeout() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let (launch, launchCalls) = makeLauncher()

        _ = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: launch
        )

        let arguments = try XCTUnwrap(launchCalls().first?.1)
        let titleIndex = try XCTUnwrap(arguments.firstIndex(of: "--title"))
        XCTAssertFalse(arguments[titleIndex + 1].isEmpty)
        let messageIndex = try XCTUnwrap(arguments.firstIndex(of: "--message"))
        XCTAssertFalse(arguments[messageIndex + 1].isEmpty)
        let timeoutIndex = try XCTUnwrap(arguments.firstIndex(of: "--timeout"))
        let timeout = try XCTUnwrap(Double(arguments[timeoutIndex + 1]))
        XCTAssertGreaterThan(timeout, 0)
    }

    /// 待つ経路 (`ProcessRunner`) で通知を送ってはならない (20.2)。
    /// 待つとダイアログ応答までインストールが返らなくなる。
    func testConfirmationNotificationIsNotSentThroughTheWaitingProcessRunner() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, runCalls) = makeAlwaysSucceedingRunProcess()
        let (launch, _) = makeLauncher()

        _ = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: launch
        )

        XCTAssertFalse(
            runCalls().contains { $0.1.contains("--title") },
            "確認用の通知は完了を待つ実行経路で送ってはならない")
    }

    func testReplacingInstallDoesNotLaunchConfirmationNotification() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        try installOnce(runProcess: runProcess, selfPath: selfPath)
        let (launch, launchCalls) = makeLauncher()

        let outcome = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: launch
        )

        XCTAssertTrue(outcome.replacedExistingBundle)
        XCTAssertTrue(launchCalls().isEmpty, "上書きインストールでは確認用の通知を出さない")
        XCTAssertFalse(outcome.sentConfirmationNotification)
    }

    /// 起動に失敗してもインストールは成功する (20.3)。
    func testInstallSucceedsWhenTheConfirmationNotificationCannotBeLaunched() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let (launch, launchCalls) = makeLauncher(succeeds: false)

        let outcome = try Installer.install(
            profile: nil,
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: launch
        )

        let naming = try ProfileNaming.resolve(profile: nil, homeDirectory: homeDirectory)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: naming.bundlePath),
            "通知を出せなくてもバンドルは配置される")
        XCTAssertEqual(launchCalls().count, 1)
        XCTAssertFalse(outcome.sentConfirmationNotification)
    }

    /// プロファイルの新規作成でも、そのバンドルの名義で確認用の通知を出す (20.1)。
    func testFreshProfileInstallLaunchesConfirmationNotificationFromTheProfileBundle() throws {
        let selfPath = makeDummySelfExecutable()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()
        let (launch, launchCalls) = makeLauncher()

        let outcome = try Installer.install(
            profile: "codex",
            iconPath: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            resolveSelfExecutablePath: { selfPath },
            runProcess: runProcess,
            launchDetached: launch
        )

        let naming = try ProfileNaming.resolve(profile: "codex", homeDirectory: homeDirectory)
        XCTAssertEqual(launchCalls().count, 1)
        XCTAssertEqual(launchCalls().first?.0, naming.machOPath)
        XCTAssertTrue(outcome.sentConfirmationNotification)
    }

    // MARK: - Uninstall (Requirement 19)

    /// テスト用に、インストール済み相当のバンドルと (任意で) PATH上のsymlinkを作る。
    @discardableResult
    private func makeInstalledBundle(profile: String? = nil, withSymlink: Bool = false) throws
        -> ProfileNaming
    {
        let naming = try ProfileNaming.resolve(profile: profile, homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(
            atPath: "\(naming.bundlePath)/Contents/MacOS", withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: naming.machOPath, contents: Data("dummy".utf8))
        if withSymlink {
            try FileManager.default.createDirectory(
                atPath: binDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: "\(binDirectory)/yobirin", withDestinationPath: naming.machOPath)
        }
        return naming
    }

    func testUninstallRemovesTheBundle() throws {
        let naming = try makeInstalledBundle()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        _ = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: naming.bundlePath))
    }

    /// 登録解除はバンドルが実在するうちに行う (19.2)。lsregisterへ渡す引数と、
    /// 呼び出し時点でバンドルがまだ存在することの両方を確認する。
    func testUninstallUnregistersFromLaunchServicesBeforeDeletingTheBundle() throws {
        let naming = try makeInstalledBundle()
        var calls: [(String, [String])] = []
        var bundleExistedAtUnregister: Bool?
        let runProcess: Installer.ProcessRunner = { path, arguments in
            calls.append((path, arguments))
            bundleExistedAtUnregister = FileManager.default.fileExists(atPath: naming.bundlePath)
            return 0
        }

        _ = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, Installer.lsregisterPath)
        XCTAssertEqual(calls.first?.1, ["-u", naming.bundlePath])
        XCTAssertEqual(bundleExistedAtUnregister, true)
    }

    func testUninstallWithMissingBundleThrowsBundleNotInstalled() throws {
        let naming = try ProfileNaming.resolve(profile: nil, homeDirectory: homeDirectory)
        let (runProcess, calls) = makeAlwaysSucceedingRunProcess()

        XCTAssertThrowsError(
            try Installer.uninstall(
                profile: nil,
                homeDirectory: homeDirectory,
                binDirectory: binDirectory,
                runProcess: runProcess
            )
        ) { error in
            XCTAssertEqual(
                error as? Installer.InstallError,
                .bundleNotInstalled(path: naming.bundlePath))
        }
        XCTAssertTrue(calls().isEmpty, "存在しないバンドルの登録解除を試みてはならない")
    }

    /// PATH上のコマンドは削除しない (19.3)。削除したバンドルを指したまま残るsymlinkは
    /// 案内のためにパスとして返すだけで、実体は残る (19.7)。
    func testUninstallKeepsTheSymlinkOnPathAndReportsItAsDangling() throws {
        let naming = try makeInstalledBundle(withSymlink: true)
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let outcome = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertEqual(outcome.danglingLinkPath, "\(binDirectory)/yobirin")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: "\(binDirectory)/yobirin")
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType, .typeSymbolicLink,
            "PATH上のsymlinkは削除してはならない")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: "\(binDirectory)/yobirin"),
            naming.machOPath)
    }

    /// 他所 (パッケージマネージャ等) を指すリンクは、削除もせず案内対象にもしない (19.3)。
    func testUninstallDoesNotReportALinkPointingElsewhere() throws {
        try makeInstalledBundle()
        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true)
        let otherTarget = tempRoot.appendingPathComponent("mise-managed-yobirin").path
        FileManager.default.createFile(atPath: otherTarget, contents: Data("other".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: "\(binDirectory)/yobirin", withDestinationPath: otherTarget)
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let outcome = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertNil(outcome.danglingLinkPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTarget))
    }

    /// PATH上に実ファイル (symlinkでない) がある場合も触らず、案内対象にしない (19.3)。
    func testUninstallDoesNotReportARealFileOnPath() throws {
        try makeInstalledBundle()
        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: "\(binDirectory)/yobirin", contents: Data("real binary".utf8))
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let outcome = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertNil(outcome.danglingLinkPath)
        XCTAssertEqual(
            FileManager.default.contents(atPath: "\(binDirectory)/yobirin"),
            Data("real binary".utf8))
    }

    /// プロファイル削除ではsymlinkに触れない (installがプロファイル時に張らないことと対称)。
    func testUninstallProfileRemovesOnlyThatBundleAndLeavesDefaultLinkAlone() throws {
        let defaultNaming = try makeInstalledBundle(withSymlink: true)
        let profileNaming = try makeInstalledBundle(profile: "codex")
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let outcome = try Installer.uninstall(
            profile: "codex",
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: profileNaming.bundlePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultNaming.bundlePath))
        XCTAssertNil(outcome.danglingLinkPath)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: "\(binDirectory)/yobirin"),
            defaultNaming.machOPath)
    }

    /// 登録解除に失敗しても削除は続行し、失敗を結果として返す (19.8)。
    func testUninstallContinuesDeletionWhenUnregisterFails() throws {
        let naming = try makeInstalledBundle()
        let runProcess: Installer.ProcessRunner = { _, _ in 7 }

        let outcome = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: naming.bundlePath))
        XCTAssertEqual(outcome.unregisterFailureExitCode, 7)
    }

    func testUninstallReportsNoUnregisterFailureOnSuccess() throws {
        try makeInstalledBundle()
        let (runProcess, _) = makeAlwaysSucceedingRunProcess()

        let outcome = try Installer.uninstall(
            profile: nil,
            homeDirectory: homeDirectory,
            binDirectory: binDirectory,
            runProcess: runProcess
        )

        XCTAssertNil(outcome.unregisterFailureExitCode)
    }
}
