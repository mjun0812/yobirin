import Darwin
import Dispatch

/// SIGTERM の受信をキャンセル入力へ変換する配線 (design.md CancellationSignal、
/// Requirements 2.5, 2.6, 2.7)。通知APIには触れない (`Dispatch` / `Darwin` のみに依存する)。
///
/// - Important: 戻り値の `DispatchSourceSignal` を保持しない限り、ソースは生きない
///   (呼び出し側が保持する契約)。`resume()` 済みのソースであっても、参照が失われれば
///   解放され、以降 SIGTERM を受信できなくなる。
/// - Important: 登録するのは SIGTERM のみであり、SIGINT には触れない
///   (requirements 2.7 の確定判断: Ctrl-C の POSIX 慣習「128+2 で終了する」という期待を
///   尊重し、`canceled` で上書きしない)。
enum CancellationSignal {
    /// SIGTERM の既定動作を無効化し、`queue` 上で `onCancel` を呼ぶソースを生成・起動する。
    ///
    /// - Parameter queue: ハンドラを実行するキュー。既定は `NSApplication` のランループと
    ///   共存する main queue (research.md DD-5)。テストではrunloop依存を避けるため専用キューを渡す。
    static func install(queue: DispatchQueue = .main, onCancel: @escaping () -> Void) -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler(handler: onCancel)
        source.resume()
        return source
    }
}
