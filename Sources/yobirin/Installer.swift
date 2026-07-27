import Darwin
import Foundation

/// バンドルへ埋め込むバージョン文字列 (design.md Installer責務)。
/// 旧 `scripts/build-app.sh` の `YOBIRIN_VERSION` 既定値 (0.1.0) を単一定数として引き継ぐ。
enum YobirinVersion {
    static let current = "0.3.0"
}

/// CLI自身によるバンドル組み立て・署名・配置・起動検証 (design.md Components and Interfaces >
/// Installer、Requirements 8.4, 8.5, 9.4, 11.1, 11.2, 11.3, 11.5, 11.6, 11.7, 11.9, 12.1)。
///
/// 通知APIの型に一切触れない (Requirement 12.1)。素のMach-Oからでも完走できる。
/// 依存 (FileManager操作を除く自己バイナリ解決・外部codesign実行) は注入可能にし、
/// テンポラリ領域でテストできる構造にしている。
enum Installer {
    /// 外部プロセス実行を差し替え可能にする関数型。戻り値は終了コード
    /// (design.md「署名は外部codesignをProcessで起動」)。
    typealias ProcessRunner = (_ executablePath: String, _ arguments: [String]) -> Int32

    /// インストール失敗の分岐を判別できるエラー (design.md フローに関する決定)。
    enum InstallError: Error, Equatable, LocalizedError {
        /// `--icon` に指定したパスが存在しない、または読み込めない。
        case iconUnreadable(path: String)
        /// 実行中の自分自身のバイナリパスを解決できなかった。
        case selfExecutableUnresolvable
        /// `codesign --force --sign -` が非0終了した。
        case codesignFailed(exitCode: Int32)
        /// 配置先が `~/Applications/<appName>.app` の形式から外れている (固定パス検証)。
        case invalidInstallDestination(expected: String, actual: String)
        /// PATH上のsymlink予定地に、symlinkではない実ファイルが存在する (非破壊で中断)。
        case existingLinkIsNotSymlink(path: String)
        /// 配置後の署名検証、または配置済みコマンドの実行確認が失敗した。
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .iconUnreadable(let path):
                return "Cannot read icon: \(path)"
            case .selfExecutableUnresolvable:
                return "Could not resolve the path of the running executable"
            case .codesignFailed(let exitCode):
                return "codesign failed (exit code: \(exitCode))"
            case .invalidInstallDestination(let expected, let actual):
                return "Unexpected install destination (expected: \(expected), actual: \(actual))"
            case .existingLinkIsNotSymlink(let path):
                return "\(path) exists and is not a symlink; aborting without overwriting"
            case .verificationFailed(let reason):
                return "Post-install verification failed: \(reason)"
            }
        }
    }

    /// PATH上のsymlink先ディレクトリを指定する環境変数名 (旧 `scripts/install.sh` を踏襲)。
    static let binDirectoryEnvironmentKey = "YOBIRIN_BIN_DIR"

    /// `install` の結果 (design.md「アイコン変化の検出 (Requirement 16)」)。
    /// 案内表示の要否はInstallCommandが判定するため、成否・終了コードには影響しない (16.5)。
    struct InstallOutcome: Equatable {
        /// 配置先に既存バンドルがあり、それを削除して置き換えたか。
        let replacedExistingBundle: Bool
        /// 新旧icnsのバイト内容が異なるか (旧icnsが読み取れない場合はtrue — 16.4の安全側)。
        let iconChanged: Bool
    }

    /// バンドルの組み立て・署名・配置・起動検証を行う (design.md インストールの処理順1〜6)。
    ///
    /// `profile` が非nilのときはPATH上のsymlink張り替えを行わない (プロファイルバンドルの
    /// 配置のみ)。symlinkは常にデフォルトバンドルを指す `yobirin` 1本であり、プロファイル選択は
    /// `--profile` ディスパッチ (ProfileDispatch) の責務であるため。
    static func install(
        profile: String? = nil,
        iconPath: String? = nil,
        homeDirectory: String = NSHomeDirectory(),
        binDirectory: String? = nil,
        fileManager: FileManager = .default,
        resolveSelfExecutablePath: () -> String? = Self.defaultResolveSelfExecutablePath,
        defaultIconData: () -> Data = { DefaultIcon.pngData },
        runProcess: ProcessRunner = Self.defaultRunProcess
    ) throws -> InstallOutcome {
        let naming = try ProfileNaming.resolve(profile: profile, homeDirectory: homeDirectory)
        let resolvedBinDirectory =
            binDirectory
            ?? ProcessInfo.processInfo.environment[binDirectoryEnvironmentKey]
            ?? "\(homeDirectory)/.local/bin"

        // 1. 一時ディレクトリへContents/{MacOS,Resources}を組み立てる。実行ファイルは実行中の
        //    自分自身 (symlink経由起動でも実体へ解決したパス) をコピーする。
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent(
            "yobirin-install-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingDir) }

        let appDir = stagingDir.appendingPathComponent("\(naming.appName).app")
        let macOSDir = appDir.appendingPathComponent("Contents/MacOS")
        let resourcesDir = appDir.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        guard let selfExecutablePath = resolveSelfExecutablePath() else {
            throw InstallError.selfExecutableUnresolvable
        }
        let executableDestination = macOSDir.appendingPathComponent(ProfileNaming.executableName)
        try fileManager.copyItem(atPath: selfExecutablePath, toPath: executableDestination.path)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executableDestination.path)

        // 2. Info.plist (Bundle ID・名前・Dock非表示・バージョン)。
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": naming.bundleID,
            "CFBundleName": naming.appName,
            "CFBundleExecutable": ProfileNaming.executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": YobirinVersion.current,
            "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon",
            "LSUIElement": true,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: appDir.appendingPathComponent("Contents/Info.plist"))

        // 3. アイコン (指定パスまたは同梱標準) をicnsとして焼き込む。
        let iconData: Data
        if let iconPath {
            guard let data = fileManager.contents(atPath: iconPath) else {
                throw InstallError.iconUnreadable(path: iconPath)
            }
            iconData = data
        } else {
            iconData = defaultIconData()
        }
        let newIconPath = resourcesDir.appendingPathComponent("AppIcon.icns").path
        try IcnsWriter.write(pngData: iconData, to: newIconPath)

        // 4. 外部codesignでad-hoc署名する (entitlementは一切付与しない)。失敗は非0。
        let signExitCode = runProcess("/usr/bin/codesign", ["--force", "--sign", "-", appDir.path])
        guard signExitCode == 0 else {
            throw InstallError.codesignFailed(exitCode: signExitCode)
        }

        // 5. 配置: 固定パス検証 → 旧バンドル削除 → コピー → symlink張り替え。
        let expectedBundlePath = "\(homeDirectory)/Applications/\(naming.appName).app"
        guard naming.bundlePath == expectedBundlePath else {
            throw InstallError.invalidInstallDestination(
                expected: expectedBundlePath, actual: naming.bundlePath)
        }

        let applicationsDirectory = "\(homeDirectory)/Applications"
        try fileManager.createDirectory(
            atPath: applicationsDirectory, withIntermediateDirectories: true)

        // アイコン変化の検出 (Requirement 16): 旧バンドル削除の前に既存icnsを読み、新icnsとバイト
        // 比較する。旧icnsが読み取れない場合は変化した可能性がある以上、変化扱いとする (16.4)。
        let bundleExisted = fileManager.fileExists(atPath: naming.bundlePath)
        let iconChanged: Bool
        if bundleExisted {
            let oldIconPath = "\(naming.bundlePath)/Contents/Resources/AppIcon.icns"
            if let oldIconData = fileManager.contents(atPath: oldIconPath) {
                iconChanged = oldIconData != fileManager.contents(atPath: newIconPath)
            } else {
                iconChanged = true
            }
        } else {
            iconChanged = false
        }

        if bundleExisted {
            try fileManager.removeItem(atPath: naming.bundlePath)
        }
        try fileManager.copyItem(atPath: appDir.path, toPath: naming.bundlePath)

        if profile == nil {
            try fileManager.createDirectory(
                atPath: resolvedBinDirectory, withIntermediateDirectories: true)
            let linkPath = "\(resolvedBinDirectory)/\(ProfileNaming.executableName)"
            // `fileExists(atPath:)` はsymlinkを辿るため、リンク先が存在しない (壊れた) symlinkを
            // 「存在しない」と誤判定する。symlink自体の有無は `attributesOfItem` (lstat相当) で見る。
            if let attributes = try? fileManager.attributesOfItem(atPath: linkPath) {
                guard (attributes[.type] as? FileAttributeType) == .typeSymbolicLink else {
                    throw InstallError.existingLinkIsNotSymlink(path: linkPath)
                }
                try fileManager.removeItem(atPath: linkPath)
            }
            try fileManager.createSymbolicLink(
                atPath: linkPath, withDestinationPath: naming.machOPath)
        }

        // 6. 署名検証と配置済みコマンドの実行確認。失敗は非0。
        let verifyExitCode = runProcess(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", naming.bundlePath])
        guard verifyExitCode == 0 else {
            throw InstallError.verificationFailed(
                "codesign --verify --deep --strict exited with code \(verifyExitCode)")
        }
        let helpExitCode = runProcess(naming.machOPath, ["--help"])
        guard helpExitCode == 0 else {
            throw InstallError.verificationFailed(
                "Running --help on the installed command exited with code \(helpExitCode)")
        }

        return InstallOutcome(replacedExistingBundle: bundleExisted, iconChanged: iconChanged)
    }

    /// 実行中の自分自身のバイナリパスを `_NSGetExecutablePath` で解決する
    /// (symlink経由起動でも実体パスへ解決する)。
    private static func defaultResolveSelfExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [Int8](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `Process` で外部実行ファイルを起動し、終了コードを返す既定実装。
    private static func defaultRunProcess(_ executablePath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
