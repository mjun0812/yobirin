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
}
