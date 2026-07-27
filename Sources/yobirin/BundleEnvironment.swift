import Foundation

/// バンドル内/外の判定ヘルパ (design.md CLIとアプリの二面性、Requirement 12.1)。
///
/// `Bundle.main.bundleIdentifier == nil` は `.app` バンドル外の素のMach-O実行を検知する。
/// 起動ゲート本体 (この判定を使った「バンドル外検知→引数なしガード/ルーティング」の配線) は
/// task 6.3 の範囲であり、ここでは判定ヘルパの提供までを行う。
enum BundleEnvironment {
    /// 現在のプロセスが `.app` バンドル外で実行されているかどうかを判定する。
    /// テストから差し替えられるよう `bundleIdentifier` を注入可能にしている
    /// (既定値は実際の `Bundle.main.bundleIdentifier`)。
    static func isOutsideBundle(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier == nil
    }

    /// symlink経由起動の再exec先を判定する純粋関数。
    ///
    /// CFBundleは実行パスのsymlinkを解決しないため、PATH上のsymlink経由でexecされると
    /// バンドル内実体を指していても `Bundle.main.bundleIdentifier` がnilになる (実測。
    /// UN層のLaunchServicesはrealpathで解決するため通知自体は出せるが、起動ゲートが
    /// バンドル外と誤判定してしまう)。バンドル未解決かつ実行パスがrealpathと異なる場合は
    /// 実体パスを返し、呼び出し側がそこへ再execすることで直接実行と同一条件に正規化する。
    /// 再exec後のプロセスは実行パス==realpathとなるため、再帰は構造的に起きない。
    static func reExecTarget(
        bundleIdentifier: String?,
        executablePath: String,
        resolvedExecutablePath: String
    ) -> String? {
        guard bundleIdentifier == nil, executablePath != resolvedExecutablePath else {
            return nil
        }
        return resolvedExecutablePath
    }

    /// 実配線: symlink経由起動なら実体パスへexecvで再実行する (成功時は返らない)。
    /// 失敗時・非該当時はそのまま返り、既存の起動ゲートフローへ進む。
    static func reExecThroughSymlinkIfNeeded() {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [Int8](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let executablePath = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard
            let target = reExecTarget(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                executablePath: executablePath,
                resolvedExecutablePath: URL(fileURLWithPath: executablePath)
                    .resolvingSymlinksInPath().path
            )
        else { return }
        var arguments = CommandLine.arguments
        arguments[0] = target
        ProfileDispatch.defaultExec(target, arguments)
    }

    /// 配置済みバンドルの `Contents/Info.plist` から `CFBundleIdentifier` /
    /// `CFBundleShortVersionString` を読む (design.md ListCommand責務 / 透過ディスパッチの
    /// バージョン比較、Requirements 14.2, 17.4)。`ListCommand` と `BundleVersionCheck`
    /// (Yobirin.swift) が共有する唯一の読み取り経路。読めないキー・plist自体は個別に `nil`
    /// (欠損) とし、呼び出し側の一覧表示・バージョン比較を止めない。
    static func readBundleInfo(bundlePath: String, fileManager: FileManager = .default) -> (
        bundleID: String?, version: String?
    ) {
        let plistPath = "\(bundlePath)/Contents/Info.plist"
        guard let data = fileManager.contents(atPath: plistPath),
            let plistObject = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let plist = plistObject as? [String: Any]
        else {
            return (nil, nil)
        }
        return (
            plist["CFBundleIdentifier"] as? String, plist["CFBundleShortVersionString"] as? String
        )
    }
}
