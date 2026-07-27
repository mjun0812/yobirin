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
        abstract: "Yobirin.appを組み立ててインストールする"
    )

    /// `Installer.install` 呼び出しを差し替え可能にする関数型 (テスト容易性のための注入点)。
    typealias InstallFunction = (_ profile: String?, _ iconPath: String?) throws ->
        Installer.InstallOutcome

    @Option(help: "導入するプロファイル名 (英小文字・数字のみ。省略時はデフォルト)")
    var profile: String?

    @Option(help: "焼き込むアイコン画像のパス (省略時は同梱の標準アイコン)")
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
                    "不正なプロファイル名です: \"\(profile)\" (使用できるのは英小文字と数字のみ)")
                exit(ResultEmitter.environmentErrorExitCode)
                return
            }
        }

        let outcome: Installer.InstallOutcome
        do {
            outcome = try install(profile, icon)
        } catch let error as Installer.InstallError {
            stderrWriter(error.errorDescription ?? "インストールに失敗しました")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        } catch {
            stderrWriter("インストールに失敗しました: \(error)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        if let naming = try? ProfileNaming.resolve(profile: profile) {
            stdoutWriter("インストールが完了しました: \(naming.bundlePath)")
        } else {
            stdoutWriter("インストールが完了しました")
        }

        // アイコン変更時の反映遅延の案内 (Requirement 16): 既存バンドルを置き換え、かつ
        // アイコンが変化したときだけ出す。案内の有無は成否・終了コードに影響しない (16.5)。
        if outcome.replacedExistingBundle && outcome.iconChanged {
            stdoutWriter(
                "アイコンの変更を通知バナーへ反映するにはログアウト→ログインが必要です (新しいプロファイル名でインストールした場合は即時反映されます)"
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
