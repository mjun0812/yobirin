import Darwin

/// ファイルディスクリプタが端末に接続されているかの判定 (design.md TerminalDetection、
/// Requirements 5.3, 12.1, 12.2, 13.1, 13.2)。
///
/// `isatty` を呼ぶ唯一の場所とし、利用側は述語 (`Predicate`) を注入で受け取る。判定対象は
/// 要件ごとに異なる (標準入力のみ / いずれか / 標準エラーのみ) ため、単一の真偽値へは畳まない
/// (research.md DD-5)。
enum TerminalDetection {
    /// ファイルディスクリプタを受けて端末接続の有無を返す述語。テストはこれを差し替える。
    ///
    /// - Note: `@Sendable` を付けない。付けるとテスト側が可変ローカル変数を捕捉できなくなる。
    ///   実装を `static let` ではなく `static func` (`defaultPredicate`) で提供しているのは、
    ///   非Sendableなクロージャを静的プロパティに保持するとSwift 6の並行性チェックに掛かるため
    ///   (既存の `ExitCoordinator.defaultWriter` / `ProfileDispatch.defaultExec` と同じ形)。
    typealias Predicate = (Int32) -> Bool

    /// 実システムへの問い合わせ。`isatty` の呼び出しはここに限る。
    static func defaultPredicate(_ descriptor: Int32) -> Bool {
        isatty(descriptor) == 1
    }

    /// 標準入力・標準出力・標準エラーのいずれかが端末に接続されているか (Requirements 12.1, 12.2)。
    ///
    /// 3本すべてを見るのは、`yobirin > file` や `yobirin 2>/dev/null` のように一部だけを
    /// リダイレクトした端末実行を、LaunchServices からの起動と取り違えないため。
    static func isAnyStandardStreamTerminal(_ predicate: Predicate = defaultPredicate) -> Bool {
        [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains(where: predicate)
    }
}
