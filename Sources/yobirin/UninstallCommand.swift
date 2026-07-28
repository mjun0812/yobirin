import ArgumentParser
import Darwin
import Foundation

/// `uninstall` サブコマンドの引数定義とインストーラへの結線 (design.md CLI契約 > uninstall、
/// Requirement 19)。
///
/// 通知APIやAppKitの型に一切触れない (Requirement 19.6)。バンドル外の素のMach-Oからでも
/// 完走できる。
struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove an installed bundle (does not remove the command on your PATH)"
    )

    /// `Installer.uninstall` 呼び出しを差し替え可能にする関数型 (テスト容易性のための注入点)。
    typealias UninstallFunction = (_ profile: String?) throws -> Installer.UninstallOutcome

    @Option(
        help: "Profile name to remove (lowercase letters and digits only; removes the default bundle when omitted)"
    )
    var profile: String?

    func run() {
        Self.perform(
            profile: profile,
            uninstall: Self.defaultUninstall,
            stdoutWriter: Self.defaultStdoutWriter,
            stderrWriter: Self.defaultStderrWriter,
            exit: { Darwin.exit($0) }
        )
    }

    /// プロファイル名の検証 (`ProfileNaming` の規約) → `Installer.uninstall` 呼び出し → 成否の
    /// メッセージ化・終了コード決定 (design.md Error Handling)。`InstallCommand.perform` と
    /// 同じ注入の形にそろえている。
    static func perform(
        profile: String?,
        uninstall: UninstallFunction,
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

        let outcome: Installer.UninstallOutcome
        do {
            outcome = try uninstall(profile)
        } catch let error as Installer.InstallError {
            stderrWriter(error.errorDescription ?? "Uninstall failed")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        } catch {
            stderrWriter("Uninstall failed: \(error)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        if let naming = try? ProfileNaming.resolve(profile: profile) {
            stdoutWriter("Uninstalled: \(naming.bundlePath)")
        } else {
            stdoutWriter("Uninstalled")
        }

        // 登録解除の失敗は削除の成否を変えない (19.8)。残った登録を手で消せるよう案内する。
        if let exitCode = outcome.unregisterFailureExitCode {
            stderrWriter(
                "Warning: could not unregister the bundle from LaunchServices (lsregister exit code: \(exitCode))"
            )
        }

        // PATH上のsymlinkは削除しない (19.3)。削除したバンドルを指したまま残る場合だけ案内する
        // (19.7)。案内の有無は成否・終了コードに影響しない。
        if let linkPath = outcome.danglingLinkPath {
            stdoutWriter(
                "Note: \(linkPath) still points to the removed bundle. Remove it yourself, or run 'yobirin install' to restore it."
            )
        }
    }

    private static func defaultUninstall(profile: String?) throws -> Installer.UninstallOutcome {
        try Installer.uninstall(profile: profile)
    }

    private static func defaultStdoutWriter(_ text: String) {
        print(text)
    }

    private static func defaultStderrWriter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
