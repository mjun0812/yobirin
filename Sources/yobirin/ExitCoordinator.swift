import Foundation

/// 出力先へのテキスト書き込みを抽象化する (design.md AppLifecycle: 遅延exit)。
///
/// 実装は `ExitCoordinator.defaultWriter` を使う。
typealias OutputWriter = (OutputDestination, String) -> Void

/// 結果出力後の遅延exit (design.md AppLifecycle / Error Handling > 再起動・孤児通知への防御、
/// Requirement 6.1)。
///
/// `EmittedOutput` を受けて (a) stdout/stderrへの書き込み (b) 既存の `Scheduler` 抽象を使った
/// 遅延後のexit、を行う。書き込み・exitの双方を注入可能にし、実プロセスへの副作用から
/// 切り離してテストできるコア部品として設計する (design許容幅0.5〜1秒のうち、実測でexit-delay 1秒
/// が安全と確認済みのため、CLIオプションにはせず内部定数とする)。
///
/// - Note: `finish` は渡された `EmittedOutput` を一度書き込むだけで、遅延中に何が起きても
///   自身で出力を再発行しない (`NotificationSession.commit` の一度きり確定機構を前提とし、
///   二重出力の防止をここで壊さない設計)。
enum ExitCoordinator {
    static let delay: TimeInterval = 1.0

    static func finish(
        _ output: EmittedOutput,
        writer: OutputWriter,
        scheduler: Scheduler,
        exit: @escaping (Int32) -> Void
    ) {
        // text が nil のときは何も書かない (Requirement 2.4: 空行も出力しない)。
        // 遅延exitは出力の有無に関わらず行う — 再起動への防御 (Requirement 6.1) は出力とは無関係。
        if let text = output.text {
            writer(output.destination, text)
        }
        _ = scheduler(delay) {
            exit(output.exitCode)
        }
    }

    /// 実装先の書き込み。stdoutは `print`、stderrは標準エラーへ改行付きで書き込む。
    ///
    /// stdoutは書き込み直後にflushする。出力先がパイプの場合stdioはフルバッファになり、
    /// flushしないと結果JSONが遅延exit後のプロセス終了まで消費者へ到達しない (Requirement 18.1)。
    static func defaultWriter(_ destination: OutputDestination, _ text: String) {
        switch destination {
        case .stdout:
            print(text)
            fflush(stdout)
        case .stderr:
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }
}
