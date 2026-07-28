import ArgumentParser
import Darwin
import Foundation

/// `install` サブコマンドの引数定義とインストーラへの結線 (design.md CLI契約 > install、
/// Requirements 9.1, 9.3, 11.1)。
///
/// 通知APIやAppKitの型に一切触れない (Requirement 12.1)。バンドル外の素のMach-Oからでも
/// 完走できる。
struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Assemble and install Yobirin.app"
    )

    /// `Installer.install` 呼び出しを差し替え可能にする関数型 (テスト容易性のための注入点)。
    typealias InstallFunction = (_ profile: String?, _ iconPath: String?) throws ->
        Installer.InstallOutcome

    @Option(
        help: "Profile name to install (lowercase letters and digits only; installs the default bundle when omitted)"
    )
    var profile: String?

    @Option(help: "Path of a PNG icon to embed (uses the bundled default icon when omitted)")
    var icon: String?

    func run() {
        Self.perform(
            profile: profile,
            icon: icon,
            install: Self.defaultInstall,
            stdoutWriter: Self.defaultStdoutWriter,
            stderrWriter: Self.defaultStderrWriter,
            exit: { Darwin.exit($0) }
        )
    }

    /// プロファイル名の検証 (`ProfileNaming` の規約) → `Installer.install` 呼び出し → 成否の
    /// メッセージ化・終了コード決定 (design.md Error Handling)。`install` / `stdoutWriter` /
    /// `stderrWriter` / `exit` を注入してテストする。
    static func perform(
        profile: String?,
        icon: String?,
        install: InstallFunction,
        stdoutWriter: (String) -> Void,
        stderrWriter: (String) -> Void,
        exit: (Int32) -> Void
    ) {
        if let profile {
            do {
                try ProfileNaming.validate(profile)
            } catch {
                stderrWriter(
                    "Invalid profile name: \"\(profile)\" (only lowercase letters and digits are allowed)")
                exit(ResultEmitter.environmentErrorExitCode)
                return
            }
        }

        let outcome: Installer.InstallOutcome
        do {
            outcome = try install(profile, icon)
        } catch let error as Installer.InstallError {
            stderrWriter(error.errorDescription ?? "Installation failed")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        } catch {
            stderrWriter("Installation failed: \(error)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        if let naming = try? ProfileNaming.resolve(profile: profile) {
            stdoutWriter("Installation complete: \(naming.bundlePath)")
        } else {
            stdoutWriter("Installation complete")
        }

        // アイコン変更時の反映遅延の案内 (Requirement 16): 既存バンドルを置き換え、かつ
        // アイコンが変化したときだけ出す。案内の有無は成否・終了コードに影響しない (16.5)。
        if outcome.replacedExistingBundle && outcome.iconChanged {
            stdoutWriter(
                "Icon changes appear in notification banners only after you log out and back in (installing under a new profile name shows the new icon immediately)"
            )
        }

        // 確認用通知の案内 (Requirement 20.5): 新規インストールで発行したときだけ出す。
        // 案内の有無は成否・終了コードに影響しない (20.3)。
        if outcome.sentConfirmationNotification {
            stdoutWriter(
                "Sent a confirmation notification. If it does not appear, check System Settings > Notifications."
            )
        }
    }

    private static func defaultInstall(profile: String?, iconPath: String?) throws
        -> Installer.InstallOutcome
    {
        try Installer.install(profile: profile, iconPath: iconPath)
    }

    private static func defaultStdoutWriter(_ text: String) {
        print(text)
    }

    private static func defaultStderrWriter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
