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
}
