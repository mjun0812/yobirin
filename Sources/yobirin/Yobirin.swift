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
        let arguments = CommandLine.arguments
        // 種別判定はバンドル内でも実行する。分岐に使わない経路でも一度パースするが、
        // `parseAsRoot` は出力も `run()` の呼び出しも伴わないため副作用がなく、
        // 「バンドル内では kind が無視される」という `decide` の内部事情に main() を
        // 依存させないほうが安全 (design.md 起動ゲートの判定)。
        let decision = LaunchGate.decide(
            arguments: arguments,
            kind: LaunchGate.classify(arguments: arguments),
            isOutsideBundle: BundleEnvironment.isOutsideBundle(),
            isDefaultBundleInstalled: FileManager.default.fileExists(
                atPath: ProfileNaming.default().machOPath),
            isInteractive: TerminalDetection.isAnyStandardStreamTerminal()
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
        case .showHelp:
            print(YobirinCommand.helpMessage())
            exit(0)
        }
    }

    private static let installGuideMessage =
        "Running outside the .app bundle. Run 'yobirin install' to install."
}

/// コマンド種別 (design.md LaunchGate / CommandKind、Requirement 11.1)。
///
/// バンドル外で実行を継続してよいかを、引数文字列の位置走査ではなくコマンド解決の結果から
/// 決めるための分類。位置走査はオプションの**値**とサブコマンド名を区別できず、
/// `--title install` のような入力でバンドル外の通知APIへ到達してクラッシュしていた
/// (research.md F1)。
enum CommandKind: Equatable {
    /// 通知APIを必要とする (`NotifyCommand` / `SweepCommand`)
    case requiresBundle
    /// バンドルが望ましいが、無くても劣化して完走する (`DoctorCommand`。Requirement 15.5)
    case diagnostic
    /// 通知APIに触れない。インストール系・一覧系・補完・ヘルプ・バージョン・引数エラーを含む
    case bundleFree
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
        /// 端末からの引数なし起動 → ヘルプを表示して正常終了 (Requirement 12.1)。
        /// 孤児通知の掃除は明示的な `sweep` サブコマンドが担う。
        case showHelp
    }

    /// 起動の分岐を決める純粋関数 (Requirements 11.3, 11.6, 12.1, 12.2, 15.5)。
    ///
    /// 種別の判定 (引数 → `CommandKind`) は `classify` の責務であり、ここでは結果を受け取る
    /// だけにする。分岐とパースを分けておかないと、この関数がテスト時にも実パーサへ依存する。
    ///
    /// - Parameters:
    ///   - isDefaultBundleInstalled: デフォルトバンドルのMach-Oが存在するか
    ///     (Requirements 17.1, 17.2)。バンドル外のときのみ参照する。
    ///   - isInteractive: 標準ストリームのいずれかが端末に接続されているか。引数なし起動の
    ///     分岐にのみ影響する (Requirements 12.1, 12.2)。
    static func decide(
        arguments: [String],
        kind: CommandKind,
        isOutsideBundle: Bool,
        isDefaultBundleInstalled: Bool = false,
        isInteractive: Bool = false
    ) -> Decision {
        if LaunchGuard.isArgumentlessLaunch(arguments) {
            // 端末から打たれた引数なし起動は、無言で終わらせずヘルプを見せる (Requirement 12.1)。
            // 非対話はLaunchServices経由の再起動とみなし、従来どおり孤児通知を掃除する (12.2)。
            if isInteractive {
                return .showHelp
            }
            guard isOutsideBundle else { return .sweepOrphans }
            return isDefaultBundleInstalled ? .execInstalledBundle : .guideInstall
        }

        guard isOutsideBundle else { return .runCLI }

        switch kind {
        case .bundleFree:
            return .runCLI
        case .requiresBundle:
            return isDefaultBundleInstalled ? .execInstalledBundle : .guideInstall
        case .diagnostic:
            // 未インストールでも案内で終わらせない。インストール状態そのものが診断対象のため
            // (Requirement 15.5)。
            return isDefaultBundleInstalled ? .execInstalledBundle : .runCLI
        }
    }

    /// 実行ファイル名を除いた引数列を解決する既定の処理。
    ///
    /// `parseAsRoot` はコマンドのインスタンスを生成するだけで `run()` を呼ばないため、
    /// 通知APIに触れずバンドル外で安全に呼べる (Requirement 11.4)。
    ///
    /// - Important: `parseAsRoot` はパースの一環で `validate()` を実行する (2026-07-30 実測)。
    ///   そのため `NotifyCommand.validate()` に副作用 (ファイル書き込み・ロック取得・標準入力の
    ///   消費) を置いてはならない。置くと引き継ぎ前のホップで副作用が起き、引き継ぎ先が
    ///   壊れる。
    static func defaultParse(_ arguments: [String]) throws -> ParsableCommand {
        try YobirinCommand.parseAsRoot(Array(arguments.dropFirst()))
    }

    /// 引数列からコマンド種別を判定する (Requirements 11.1, 11.2, 11.5, 8.4, 8.6)。
    ///
    /// 分類は**返ってきたコマンドの型**で行う。`--help` / `-h` は throw せずヘルプ用コマンドと
    /// して解決されるため (2026-07-30 実測)、throw の有無で分けると取りこぼす。解決に失敗した
    /// 場合 (`--version` / 補完スクリプト要求 / 引数エラー) も、バンドルへ引き継がず
    /// ArgumentParser にその場で処理させるため `bundleFree` とする。
    ///
    /// - Note: サブコマンドを追加したら、それがバンドルを必要とするかをここへ反映すること。
    ///   反映を忘れると `bundleFree` に落ち、バンドル外で通知APIへ到達する。
    static func classify(
        arguments: [String],
        parse: ([String]) throws -> ParsableCommand = defaultParse
    ) -> CommandKind {
        guard let command = try? parse(arguments) else {
            return .bundleFree
        }
        switch command {
        case is NotifyCommand, is SweepCommand:
            return .requiresBundle
        case is DoctorCommand:
            return .diagnostic
        default:
            return .bundleFree
        }
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
    /// - Parameter isStandardErrorTerminal: 標準エラーが端末に接続されているか (Requirement 13)。
    ///   バージョン不一致の案内は、この値が真のときだけ出す。hookから毎回呼ばれる用途で案内が
    ///   毎回出るとログを埋めるため。exec失敗のような本物のエラーはこの値に関わらず出す。
    static func execDefaultBundle(
        naming: ProfileNaming = .default(),
        arguments: [String] = CommandLine.arguments,
        currentVersion: String = YobirinVersion.current,
        fileManager: FileManager = .default,
        isStandardErrorTerminal: Bool = TerminalDetection.defaultPredicate(STDERR_FILENO),
        stderrWriter: (String) -> Void = Self.defaultStderrWriter,
        exit: (Int32) -> Void = { Darwin.exit($0) },
        exec: ProfileDispatch.Exec = ProfileDispatch.defaultExec
    ) {
        if isStandardErrorTerminal,
            let notice = BundleVersionCheck.updateNotice(
                bundlePath: naming.bundlePath, currentVersion: currentVersion, fileManager: fileManager
            )
        {
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
        abstract: "Deliver a macOS notification and wait for the response",
        version: YobirinVersion.current,
        subcommands: [
            NotifyCommand.self, InstallCommand.self, UninstallCommand.self, ListCommand.self,
            PsCommand.self, CompletionCommand.self, SweepCommand.self, DoctorCommand.self,
        ],
        defaultSubcommand: NotifyCommand.self
    )
}
