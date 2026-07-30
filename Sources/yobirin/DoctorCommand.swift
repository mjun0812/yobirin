import ArgumentParser
import Darwin
import Dispatch
import Foundation
import UserNotifications

/// `doctor` サブコマンドの診断項目の収集・判定・整形 (design.md DoctorCommand、Requirement 15)。
///
/// 「通知が出ない」の切り分けを1コマンドで済ませるための診断。インストール状態・バージョン整合・
/// PATH上のリンク・通知許可を報告する。
///
/// - Note (import規律の例外): 通知許可の状態を報告するため、本コマンドは通知系に分類される
///   (research.md DD-3)。`install` / `uninstall` / `list` / `ps` / `completion` が通知APIに
///   触れないという既存の不変条件は維持される。通知APIの**呼び出し**はバンドル内であることを
///   実行時に確認してから行う (task 2.5)。
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the installation, version match, PATH link, and notification permission",
        discussion: """
            Exits non-zero when the diagnosis finds a problem. A non-zero exit means \
            "problems were found", not "the command failed".

            The notification permission can only be inspected from inside the app bundle. \
            When it cannot be determined it is reported as unknown and does not count as a problem.
            """
    )

    /// 診断項目の状態。`unknown` は判定できなかったことを表し、問題としては数えない
    /// (Requirement 15.5: バンドル外での通知許可など)。
    enum Status: String, Equatable {
        case ok
        case warning
        case failure
        case unknown
    }

    /// 診断1項目。`remedy` は次に取るべき操作 (Requirement 15.6)。
    /// `ok` / `unknown` のときは対処が無いため `nil`。
    struct Check: Equatable {
        let name: String
        let status: Status
        let detail: String
        let remedy: String?
    }

    private static let installRemedy = "Run 'yobirin install'."

    @Flag(help: "Print the diagnosis as machine-readable JSON to stdout")
    var json = false

    func run() {
        let homeDirectory = ProfileNaming.resolvedHomeDirectory()
        let checks =
            Self.collectChecks(
                currentVersion: YobirinVersion.current,
                homeDirectory: homeDirectory,
                binDirectory: Installer.resolvedBinDirectory(homeDirectory: homeDirectory),
                fileManager: .default,
                listDirectory: { try FileManager.default.contentsOfDirectory(atPath: $0) }
            )
            + [
                Self.permissionCheck(
                    isOutsideBundle: BundleEnvironment.isOutsideBundle(),
                    client: UNNotificationCenterAdapter()
                )
            ]

        Self.perform(
            json: json,
            checks: checks,
            stdoutWriter: { print($0) },
            exit: { Darwin.exit($0) }
        )
    }

    /// 判定 → 整形 → 終了コードの決定 (Requirements 15.7, 15.8, 15.9)。
    /// `checks` / `stdoutWriter` / `exit` を注入してテストする。
    ///
    /// 終了コードが非0でも「コマンドの実行に失敗した」ではなく「診断で問題が見つかった」を
    /// 意味する。この違いは `configuration.discussion` でヘルプに明記する。
    static func perform(
        json: Bool,
        checks: [Check],
        stdoutWriter: (String) -> Void,
        exit: (Int32) -> Void
    ) {
        let problems = checks.filter { $0.status == .warning || $0.status == .failure }.count

        stdoutWriter(json ? jsonString(for: checks, problems: problems) : textString(for: checks, problems: problems))
        exit(problems == 0 ? 0 : ResultEmitter.environmentErrorExitCode)
    }

    /// 通知許可の状態 (Requirements 15.4, 15.5)。
    ///
    /// **`requestAuthorization` を呼んではならない。** 呼ぶと診断のたびに許可を要求することに
    /// なり、未許可の初回は許可ダイアログが出る。読み取り専用の `getAuthorizationStatus` のみを
    /// 使う (design.md DoctorCommand)。
    ///
    /// バンドル外では `UNUserNotificationCenter.current()` が例外死する (steering tech.md 制約1)
    /// ため、通知APIに触れずに判定不能を返す。判定不能は問題として数えないので、バンドル未
    /// インストールの環境でも診断そのものは完走する (Requirement 15.5)。
    ///
    /// 応答は非同期コールバックで返る。`NSApplication.run()` を経由しないため、
    /// `LaunchGuard.sweepDeliveredNotifications` と同じくセマフォとタイムアウトで待つ。
    /// UN側がハングした場合はタイムアウトして判定不能に落ちる。
    static func permissionCheck(
        isOutsideBundle: Bool,
        client: NotificationCenterClient,
        timeout: DispatchTimeInterval = .seconds(2)
    ) -> Check {
        guard !isOutsideBundle else {
            return Check(
                name: "permission",
                status: .unknown,
                detail: "Cannot be determined outside the app bundle",
                remedy: nil
            )
        }

        guard let status = AuthorizationStatusProbe(client: client).read(timeout: timeout) else {
            return Check(
                name: "permission",
                status: .unknown,
                detail: "The notification center did not respond in time",
                remedy: nil
            )
        }

        let bundleName = ProfileNaming.default().appName
        switch status {
        case .authorized, .provisional, .ephemeral:
            return Check(name: "permission", status: .ok, detail: "Authorized", remedy: nil)
        case .denied:
            return Check(
                name: "permission",
                status: .failure,
                detail: "Denied",
                remedy: "Enable notifications in System Settings > Notifications > \(bundleName)."
            )
        case .notDetermined:
            return Check(
                name: "permission",
                status: .warning,
                detail: "Not requested yet",
                remedy: "Run 'yobirin install' to request permission."
            )
        @unknown default:
            return Check(
                name: "permission",
                status: .unknown,
                detail: "Unrecognized authorization status",
                remedy: nil
            )
        }
    }

    // MARK: - Text formatting (状態と項目名を桁揃えし、対処は続く行へ字下げして置く)

    private static func textString(for checks: [Check], problems: Int) -> String {
        let statusWidth = checks.map(\.status.rawValue.count).max() ?? 0
        let nameWidth = checks.map(\.name.count).max() ?? 0

        var lines: [String] = []
        for check in checks {
            let status = check.status.rawValue.padding(toLength: statusWidth, withPad: " ", startingAt: 0)
            let name = check.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            lines.append("\(status)  \(name)  \(check.detail)")
            if let remedy = check.remedy {
                lines.append(String(repeating: " ", count: statusWidth + nameWidth + 4) + "-> \(remedy)")
            }
        }

        lines.append("")
        lines.append(problems == 0 ? "No problems found" : "\(problems) problem(s) found")
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON formatting (design.md doctorのAPI契約)

    private static func jsonString(for checks: [Check], problems: Int) -> String {
        let items = checks.map { check -> String in
            let pairs: [(String, String)] = [
                ("name", jsonStringLiteral(check.name)),
                ("status", jsonStringLiteral(check.status.rawValue)),
                ("detail", jsonStringLiteral(check.detail)),
                ("remedy", check.remedy.map(jsonStringLiteral) ?? "null"),
            ]
            return "{\(pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ","))}"
        }
        return "{\"checks\":[\(items.joined(separator: ","))],\"problems\":\(problems)}"
    }

    /// 文字列をJSON文字列リテラルへエンコードする (`ListCommand` / `PsCommand` と同じ方針)。
    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return json
    }

    /// 診断項目の収集 (Requirements 15.1, 15.2, 15.3, 15.6)。
    ///
    /// ファイル走査に関わる入力をすべて引数で受け取り、テンポラリ領域に対してテストできるように
    /// する (`ListCommand` / `Installer` と同じ方針)。通知許可の判定は含まない — 通知APIに
    /// 触れるため、バンドル内であることを確認したうえで別途付け足す (task 2.5)。
    static func collectChecks(
        currentVersion: String,
        homeDirectory: String,
        binDirectory: String,
        fileManager: FileManager,
        listDirectory: (String) throws -> [String]
    ) -> [Check] {
        let naming = ProfileNaming.default(homeDirectory: homeDirectory)
        let installedVersion =
            fileManager.fileExists(atPath: naming.bundlePath)
            ? BundleEnvironment.readBundleInfo(bundlePath: naming.bundlePath, fileManager: fileManager).version
            : nil

        return [
            bundleCheck(naming: naming, installedVersion: installedVersion, fileManager: fileManager),
            profilesCheck(homeDirectory: homeDirectory, fileManager: fileManager, listDirectory: listDirectory),
            versionCheck(installedVersion: installedVersion, currentVersion: currentVersion),
            linkCheck(naming: naming, binDirectory: binDirectory, fileManager: fileManager),
        ]
    }

    // MARK: - 個別の診断項目

    private static func bundleCheck(
        naming: ProfileNaming, installedVersion: String?, fileManager: FileManager
    ) -> Check {
        guard fileManager.fileExists(atPath: naming.bundlePath) else {
            return Check(
                name: "bundle",
                status: .failure,
                detail: "Not installed: \(naming.bundlePath)",
                remedy: installRemedy
            )
        }
        return Check(
            name: "bundle",
            status: .ok,
            detail: "\(naming.bundlePath) (version \(installedVersion ?? "unknown"))",
            remedy: nil
        )
    }

    /// プロファイルバンドルの一覧。0件でも正常 (プロファイルは任意の機能)。
    /// バンドル名の逆引きは `ProfileNaming.recognize` に委ねる (命名規約の単一ソース)。
    ///
    /// ディレクトリが存在しない場合は0件と同義だが、存在するのに列挙できない場合は判定不能と
    /// して区別する。ここを0件と丸めると、走査に失敗しただけなのに「プロファイルは無い」と
    /// 誤報することになる。
    private static func profilesCheck(
        homeDirectory: String, fileManager: FileManager, listDirectory: (String) throws -> [String]
    ) -> Check {
        let applicationsDirectory = "\(homeDirectory)/Applications"
        guard fileManager.fileExists(atPath: applicationsDirectory) else {
            return Check(name: "profiles", status: .ok, detail: "No profile bundles", remedy: nil)
        }
        guard let itemNames = try? listDirectory(applicationsDirectory) else {
            return Check(
                name: "profiles",
                status: .unknown,
                detail: "Could not read \(applicationsDirectory)",
                remedy: nil
            )
        }

        let profiles = itemNames.compactMap { itemName -> String? in
            guard
                case .profile(let name)? = ProfileNaming.recognize(
                    appDirectoryName: itemName, homeDirectory: homeDirectory)
            else { return nil }
            return name
        }.sorted()

        return Check(
            name: "profiles",
            status: .ok,
            detail: profiles.isEmpty ? "No profile bundles" : profiles.joined(separator: ", "),
            remedy: nil
        )
    }

    private static func versionCheck(installedVersion: String?, currentVersion: String) -> Check {
        guard let installedVersion else {
            return Check(
                name: "version",
                status: .unknown,
                detail: "No installed bundle to compare with (this binary is \(currentVersion))",
                remedy: nil
            )
        }
        guard installedVersion != currentVersion else {
            return Check(name: "version", status: .ok, detail: currentVersion, remedy: nil)
        }
        return Check(
            name: "version",
            status: .warning,
            detail: "Installed bundle is \(installedVersion) but this binary is \(currentVersion)",
            remedy: "Run 'yobirin install' to update the bundle."
        )
    }

    /// PATH上のリンクの有無と指し先。`fileExists(atPath:)` はsymlinkを辿るため、壊れたリンクを
    /// 「存在しない」と誤判定する。リンク自体の有無は `attributesOfItem` (lstat相当) で見る
    /// (`Installer` と同じ作法)。
    private static func linkCheck(
        naming: ProfileNaming, binDirectory: String, fileManager: FileManager
    ) -> Check {
        let linkPath = "\(binDirectory)/\(ProfileNaming.executableName)"

        guard let attributes = try? fileManager.attributesOfItem(atPath: linkPath) else {
            return Check(
                name: "link",
                status: .warning,
                detail: "Missing: \(linkPath)",
                remedy: installRemedy
            )
        }
        guard (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
            let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath)
        else {
            return Check(
                name: "link",
                status: .warning,
                detail: "\(linkPath) exists but is not a symlink",
                remedy: "Remove it, then run 'yobirin install'."
            )
        }
        guard fileManager.fileExists(atPath: destination) else {
            return Check(
                name: "link",
                status: .warning,
                detail: "Dangling: \(linkPath) points to \(destination)",
                remedy: installRemedy
            )
        }
        guard destination == naming.machOPath else {
            return Check(
                name: "link",
                status: .warning,
                detail: "\(linkPath) points to \(destination), not \(naming.machOPath)",
                remedy: installRemedy
            )
        }
        return Check(name: "link", status: .ok, detail: "\(linkPath) -> \(destination)", remedy: nil)
    }
}

/// `client` (`Sendable` に準拠しない existential) を `@Sendable` completionHandler内で安全に
/// 捕捉し、非同期の許可状態取得を同期的に待つための薄いラッパー
/// (`LaunchGuard.DeliveredNotificationSweep` と同じパターン)。
///
/// 応答が来なければ `nil` を返す。呼び出し元はそれを判定不能として扱う。
private final class AuthorizationStatusProbe: @unchecked Sendable {
    private let client: NotificationCenterClient
    private let lock = NSLock()
    private var status: UNAuthorizationStatus?

    init(client: NotificationCenterClient) {
        self.client = client
    }

    func read(timeout: DispatchTimeInterval) -> UNAuthorizationStatus? {
        let finished = DispatchSemaphore(value: 0)
        client.getAuthorizationStatus { [self] value in
            lock.lock()
            status = value
            lock.unlock()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timeout)

        lock.lock()
        defer { lock.unlock() }
        return status
    }
}
