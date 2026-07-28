import ArgumentParser
import Darwin
import Foundation

/// プロセスの実エントリポイント。起動ゲート (design.md 起動ゲートとインストールのフロー、
/// Requirements 12.1, 12.2, 12.3) はArgumentParserより先に効かなければならないため、
/// `@main` はここに置き、`YobirinCommand` 側には付けない。
///
/// バンドル判定は既定引数 (実際の `Bundle.main.bundleIdentifier`) を使う。ここが唯一の
/// 実配線であり、テストは `LaunchGate.decide` へ `isOutsideBundle` を直接注入して検証する
/// (6.1の注意: xctestホストは `Bundle.main.bundleIdentifier` が非nilのため、この既定引数
/// 経由では「バンドル外」をシミュレートできない)。
@main
enum YobirinMain {
    static func main() {
        // symlink経由起動 (CFBundleがバンドルを解決できない) は実体パスへ再execして
        // 直接実行と同一条件に正規化してからゲート判定する (詳細はBundleEnvironment参照)。
        BundleEnvironment.reExecThroughSymlinkIfNeeded()
        let decision = LaunchGate.decide(
            arguments: CommandLine.arguments,
            isOutsideBundle: BundleEnvironment.isOutsideBundle(),
            isDefaultBundleInstalled: FileManager.default.fileExists(
                atPath: ProfileNaming.default().machOPath)
        )
        switch decision {
        case .sweepOrphans:
            LaunchGuard.cleanUpAndExit(client: UNNotificationCenterAdapter(), exit: { exit($0) })
        case .runCLI:
            YobirinCommand.main()
        case .guideInstall:
            FileHandle.standardError.write(Data((installGuideMessage + "\n").utf8))
            exit(ResultEmitter.environmentErrorExitCode)
        case .execInstalledBundle:
            BundleHandoff.execDefaultBundle()
        }
    }

    private static let installGuideMessage =
        "Running outside the .app bundle. Run 'yobirin install' to install."
}

/// 起動ゲートの判定 (design.md 起動ゲートとインストールのフロー、
/// Requirements 12.1, 12.2, 12.3)。
///
/// 「バンドル外検知 → バンドル内なら引数なしガード→ルーティング / バンドル外ならコマンド種別で
/// 分岐」の構造をテスト可能な純粋関数として提供する。通知APIの型には一切触れない。
enum LaunchGate {
    enum Decision: Equatable {
        /// バンドル内・引数なし起動 → 孤児通知を掃除して即exit (既存の `LaunchGuard` 経路)
        case sweepOrphans
        /// ArgumentParserのルーティングへ委ねる (バンドル内の通常起動、
        /// バンドル外のinstall/--help/-h/--version)
        case runCLI
        /// バンドル外での通知系要求・引数なし起動、かつデフォルトバンドルが未インストール
        /// → インストール案内をstderrへ出し非0終了 (Requirements 12.2, 12.3。クラッシュしない)
        case guideInstall
        /// バンドル外での通知系要求・引数なし起動、かつデフォルトバンドルがインストール済み
        /// → バンドル内Mach-Oへ実行を引き継ぐ (Requirements 17.1, 17.2)。実際のexec配線・
        /// バージョン不一致案内は task 13.2 が行う。
        case execInstalledBundle
    }

    /// - Parameter isDefaultBundleInstalled: デフォルトバンドルのMach-Oが存在するか
    ///   (Requirement 17.1, 17.2)。バンドル外で通知系要求・引数なし起動のときのみ参照する。
    static func decide(
        arguments: [String],
        isOutsideBundle: Bool,
        isDefaultBundleInstalled: Bool = false
    ) -> Decision {
        guard isOutsideBundle else {
            return LaunchGuard.isArgumentlessLaunch(arguments) ? .sweepOrphans : .runCLI
        }
        if isRoutableOutsideBundle(arguments) {
            return .runCLI
        }
        return isDefaultBundleInstalled ? .execInstalledBundle : .guideInstall
    }

    /// バンドル外で継続してよいコマンド種別か (Requirement 12.1: インストール系とヘルプは
    /// 通知機能に依存せず完了しなければならない)。
    ///
    /// `--help` / `-h` / `--version` は引数列のどこにあってもArgumentParserが解釈するため
    /// 位置を問わず検出する。インストール系サブコマンドは実行ファイル名を除く最初の非フラグ引数のみを見る
    /// (design.md フローチャートの `outCmd` 分岐)。
    private static func isRoutableOutsideBundle(_ arguments: [String]) -> Bool {
        let rest = arguments.dropFirst()
        if rest.contains("--help") || rest.contains("-h") || rest.contains("--version") {
            return true
        }
        return ["install", "uninstall", "list", "ps"].contains(rest.first { !$0.hasPrefix("-") })
    }
}

/// 引き継ぎ先バンドルとのバージョン比較 (design.md 透過ディスパッチの詳細、Requirement 17.4)。
/// バンドルのInfo.plist (`CFBundleShortVersionString`) と自身の `YobirinVersion.current` を
/// 比較し、一致すれば無言 (`nil`)、不一致なら更新案内の文言を返す純粋関数。stdoutを汚さないため
/// (17.4)、呼び出し側がこの文言をstderrへ書く。Info.plistの読み取りは `ListCommand` と共有する
/// `BundleEnvironment.readBundleInfo` を使い、実装を重複させない。
enum BundleVersionCheck {
    static func updateNotice(
        bundlePath: String,
        currentVersion: String = YobirinVersion.current,
        fileManager: FileManager = .default
    ) -> String? {
        guard
            let installedVersion = BundleEnvironment.readBundleInfo(
                bundlePath: bundlePath, fileManager: fileManager
            ).version,
            installedVersion != currentVersion
        else {
            return nil
        }
        return
            "note: installed bundle is \(installedVersion) but this binary is \(currentVersion); "
            + "run 'yobirin install' to update"
    }
}

/// `.execInstalledBundle` 決定時の実引き継ぎ (design.md 透過ディスパッチの詳細、
/// Requirements 17.1, 17.2, 17.4, 17.5, 17.7)。
///
/// argv[0]をデフォルトバンドル内Mach-Oのパスへ差し替えるだけで、残りの引数 (`--profile` を
/// 含む) はそのまま透過する。バンドル内で起動された `NotifyCommand` が `--profile` を見て
/// 二段目のディスパッチ (`ProfileDispatch.dispatch`) を行うため、ここでは除去しない
/// (design.md「--profile 付きの引数もそのまま透過し、バンドル内のNotifyCommand経由で
/// プロファイルへ二段ディスパッチされる」)。exec機構は `ProfileDispatch.defaultExec` を共用し、
/// 失敗時の処理は `ProfileDispatch.dispatch` と同型 (理由をstderrへ出し
/// `environmentErrorExitCode` で終了) にする。引き継ぎ先はバンドル内実行になるため
/// 再帰は構造的に起きない (17.7)。
enum BundleHandoff {
    static func execDefaultBundle(
        naming: ProfileNaming = .default(),
        arguments: [String] = CommandLine.arguments,
        currentVersion: String = YobirinVersion.current,
        fileManager: FileManager = .default,
        stderrWriter: (String) -> Void = Self.defaultStderrWriter,
        exit: (Int32) -> Void = { Darwin.exit($0) },
        exec: ProfileDispatch.Exec = ProfileDispatch.defaultExec
    ) {
        if let notice = BundleVersionCheck.updateNotice(
            bundlePath: naming.bundlePath, currentVersion: currentVersion, fileManager: fileManager
        ) {
            stderrWriter(notice)
        }

        exec(naming.machOPath, [naming.machOPath] + arguments.dropFirst())

        // execvはプロセス置換に成功すると返らない。ここに到達するのは失敗時のみ。
        stderrWriter(
            "Failed to hand off to installed bundle: \(String(cString: strerror(errno)))")
        exit(ResultEmitter.environmentErrorExitCode)
    }

    private static func defaultStderrWriter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// ルートコマンド。サブコマンド構成に再編し、通知送信は既定サブコマンド `NotifyCommand` へ
/// 分離する (design.md CLI契約)。従来の `yobirin --title <str> --message <str> ...` は
/// `defaultSubcommand` によりそのまま `NotifyCommand` へ解決され、互換を保つ
/// (Requirement 11.8)。
struct YobirinCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yobirin",
        version: YobirinVersion.current,
        subcommands: [
            NotifyCommand.self, InstallCommand.self, UninstallCommand.self, ListCommand.self,
            PsCommand.self,
        ],
        defaultSubcommand: NotifyCommand.self
    )
}
