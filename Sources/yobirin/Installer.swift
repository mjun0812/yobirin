import Darwin
import Foundation

/// バンドルへ埋め込むバージョン文字列 (design.md Installer責務)。
/// 旧 `scripts/build-app.sh` の `YOBIRIN_VERSION` 既定値 (0.1.0) を単一定数として引き継ぐ。
enum YobirinVersion {
    static let current = "1.1.0"
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

    /// 外部プロセスを起動するだけで完了を待たない実行 (Requirement 20.2)。戻り値は起動できたか。
    ///
    /// 終了コードを見る `ProcessRunner` とは別経路にする。確認用の通知は初回インストールで
    /// 通知許可ダイアログを開くが、ダイアログ表示中はタイムアウトが進まないため、待つと
    /// インストールが返らなくなる。
    typealias DetachedProcessLauncher = (_ executablePath: String, _ arguments: [String]) -> Bool

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
        /// アンインストール対象のバンドルが存在しない (Requirement 19.4)。
        case bundleNotInstalled(path: String)

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
            case .bundleNotInstalled(let path):
                return "Not installed: \(path)"
            }
        }
    }

    /// PATH上のsymlink先ディレクトリを指定する環境変数名 (旧 `scripts/install.sh` を踏襲)。
    static let binDirectoryEnvironmentKey = "YOBIRIN_BIN_DIR"

    /// 新規インストール直後に出す確認用通知の内容 (Requirement 20.1)。
    ///
    /// 正のタイムアウトを必ず付ける。応答がなければ既存のタイムアウト処理 (Requirement 5.2) が
    /// 配信済み通知を削除するため、通知センターに残らない (20.6)。
    enum ConfirmationNotification {
        static let title = "Installation complete"
        static let message = "yobirin can now deliver notifications."
        static let timeoutSeconds = 30

        static var arguments: [String] {
            ["--title", title, "--message", message, "--timeout", String(timeoutSeconds)]
        }
    }

    /// LaunchServicesの登録操作コマンド (Requirement 19.2)。
    static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
        + "/Support/lsregister"

    /// `install` の結果 (design.md「アイコン変化の検出 (Requirement 16)」)。
    /// 案内表示の要否はInstallCommandが判定するため、成否・終了コードには影響しない (16.5)。
    struct InstallOutcome: Equatable {
        /// 配置先に既存バンドルがあり、それを削除して置き換えたか。
        let replacedExistingBundle: Bool
        /// 新旧icnsのバイト内容が異なるか (旧icnsが読み取れない場合はtrue — 16.4の安全側)。
        let iconChanged: Bool
        /// 確認用の通知を発行したか (Requirement 20.5の案内要否)。発行の成否は
        /// インストールの成否・終了コードに影響しない (20.3)。
        let sentConfirmationNotification: Bool
    }

    /// バンドルの組み立て・署名・配置・起動検証を行う (design.md インストールの処理順1〜6)。
    ///
    /// `profile` が非nilのときはPATH上のsymlink張り替えを行わない (プロファイルバンドルの
    /// 配置のみ)。symlinkは常にデフォルトバンドルを指す `yobirin` 1本であり、プロファイル選択は
    /// `--profile` ディスパッチ (ProfileDispatch) の責務であるため。
    static func install(
        profile: String? = nil,
        iconPath: String? = nil,
        homeDirectory: String = ProfileNaming.resolvedHomeDirectory(),
        binDirectory: String? = nil,
        fileManager: FileManager = .default,
        resolveSelfExecutablePath: () -> String? = Self.defaultResolveSelfExecutablePath,
        defaultIconData: () -> Data = { DefaultIcon.pngData },
        runProcess: ProcessRunner = Self.defaultRunProcess,
        launchDetached: DetachedProcessLauncher = Self.defaultLaunchDetached
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

        // 7. 新規インストールのときだけ確認用の通知を出す (Requirement 20.1, 20.4)。応答は待たず、
        //    起動できなくてもインストールの成否・終了コードを変えない (20.2, 20.3)。
        let sentConfirmationNotification =
            bundleExisted ? false : launchDetached(naming.machOPath, ConfirmationNotification.arguments)

        return InstallOutcome(
            replacedExistingBundle: bundleExisted,
            iconChanged: iconChanged,
            sentConfirmationNotification: sentConfirmationNotification
        )
    }

    /// `uninstall` の結果 (Requirement 19.7, 19.8)。
    /// 案内表示の要否はUninstallCommandが判定するため、成否・終了コードには影響しない。
    struct UninstallOutcome: Equatable {
        /// 削除したバンドルのMach-Oを指したままPATH上に残ったsymlink (無ければnil)。
        /// 削除はせず、案内のためだけに返す (19.3, 19.7)。
        let danglingLinkPath: String?
        /// LaunchServices登録の解除が失敗したときの終了コード (成功時はnil)。
        let unregisterFailureExitCode: Int32?
    }

    /// バンドルの削除とLaunchServices登録の解除を行う (Requirement 19)。
    ///
    /// **PATH上のコマンドは削除しない** (19.3)。`install` が張るsymlinkは1本だが、PATH上には
    /// mise / Homebrew が管理する同名の実バイナリが存在しうる (実測: mise導入時は
    /// `command -v yobirin` がmise管理の実バイナリを指す)。これらを消すとパッケージマネージャの
    /// 管理状態を壊すため、削除対象はバンドルとその登録に限り、削除したバンドルを指したまま残る
    /// symlinkは案内のために返すだけにする (19.7)。
    ///
    /// 登録解除はバンドルが実在するうちに行い、失敗しても削除は続行する (19.8)。
    static func uninstall(
        profile: String? = nil,
        homeDirectory: String = ProfileNaming.resolvedHomeDirectory(),
        binDirectory: String? = nil,
        fileManager: FileManager = .default,
        runProcess: ProcessRunner = Self.defaultRunProcess
    ) throws -> UninstallOutcome {
        let naming = try ProfileNaming.resolve(profile: profile, homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: naming.bundlePath) else {
            throw InstallError.bundleNotInstalled(path: naming.bundlePath)
        }

        let unregisterExitCode = runProcess(lsregisterPath, ["-u", naming.bundlePath])
        try fileManager.removeItem(atPath: naming.bundlePath)

        let resolvedBinDirectory =
            binDirectory
            ?? ProcessInfo.processInfo.environment[binDirectoryEnvironmentKey]
            ?? "\(homeDirectory)/.local/bin"
        let linkPath = "\(resolvedBinDirectory)/\(ProfileNaming.executableName)"
        // `fileExists(atPath:)` はsymlinkを辿るため、削除直後の壊れたsymlinkを「存在しない」と
        // 誤判定する。symlink自体の有無は `attributesOfItem` (lstat相当) で見る (installと同じ作法)。
        var danglingLinkPath: String?
        if let attributes = try? fileManager.attributesOfItem(atPath: linkPath),
            (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
            let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath),
            destination == naming.machOPath
        {
            danglingLinkPath = linkPath
        }

        return UninstallOutcome(
            danglingLinkPath: danglingLinkPath,
            unregisterFailureExitCode: unregisterExitCode == 0 ? nil : unregisterExitCode
        )
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

    /// 完了を待たずに外部実行ファイルを起動する既定実装 (Requirement 20.2)。
    ///
    /// 標準入出力は `/dev/null` へ向ける。待たない以上この子プロセスは親の終了後も生き続けるため
    /// (実測)、継承したままだとタイムアウト時の結果JSONが数十秒後に呼び出し元のstdoutへ紛れ込む。
    private static func defaultLaunchDetached(_ executablePath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
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
