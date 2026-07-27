import ArgumentParser
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
            isOutsideBundle: BundleEnvironment.isOutsideBundle()
        )
        switch decision {
        case .sweepOrphans:
            LaunchGuard.cleanUpAndExit(client: UNNotificationCenterAdapter(), exit: { exit($0) })
        case .runCLI:
            YobirinCommand.main()
        case .guideInstall:
            FileHandle.standardError.write(Data((installGuideMessage + "\n").utf8))
            exit(ResultEmitter.environmentErrorExitCode)
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
        /// バンドル外での通知系要求・引数なし起動 → インストール案内をstderrへ出し非0終了
        /// (Requirements 12.2, 12.3。クラッシュしない)
        case guideInstall
    }

    static func decide(arguments: [String], isOutsideBundle: Bool) -> Decision {
        guard isOutsideBundle else {
            return LaunchGuard.isArgumentlessLaunch(arguments) ? .sweepOrphans : .runCLI
        }
        return isRoutableOutsideBundle(arguments) ? .runCLI : .guideInstall
    }

    /// バンドル外で継続してよいコマンド種別か (Requirement 12.1: インストール系とヘルプは
    /// 通知機能に依存せず完了しなければならない)。
    ///
    /// `--help` / `-h` / `--version` は引数列のどこにあってもArgumentParserが解釈するため
    /// 位置を問わず検出する。`install` / `list` は実行ファイル名を除く最初の非フラグ引数のみを見る
    /// (design.md フローチャートの `outCmd` 分岐)。
    private static func isRoutableOutsideBundle(_ arguments: [String]) -> Bool {
        let rest = arguments.dropFirst()
        if rest.contains("--help") || rest.contains("-h") || rest.contains("--version") {
            return true
        }
        return ["install", "list", "ps"].contains(rest.first { !$0.hasPrefix("-") })
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
        subcommands: [NotifyCommand.self, InstallCommand.self, ListCommand.self, PsCommand.self],
        defaultSubcommand: NotifyCommand.self
    )
}
