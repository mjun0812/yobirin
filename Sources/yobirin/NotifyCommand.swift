import AppKit
import ArgumentParser
import Foundation

/// 通知送信の既定サブコマンド (design.md CLI契約、Requirements 1, 2, 4, 5)。
/// ルートコマンド (`YobirinCommand`) の `defaultSubcommand` に指定され、従来の
/// `yobirin --title <str> --message <str> ...` 形式はそのままこのサブコマンドへ解決される
/// (Requirement 11.8)。
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notify")

    @Option(help: "通知のタイトル")
    var title: String

    @Option(help: "通知の本文")
    var message: String

    @Option(help: "指定したプロファイルのバンドルへ切り替えて配信する")
    var profile: String?

    @Option(help: "通知のサブタイトル")
    var subtitle: String?

    @Option(help: "同一identifierの既存通知を置き換えるグループ")
    var group: String?

    @Option(help: "応答を待つ秒数 (省略時は無期限)。正の数値のみ許容", transform: Self.parseTimeout)
    var timeout: Double?

    @Option(help: "アクションボタンのラベル (複数指定可)")
    var action: [String] = []

    @Flag(help: "reply入力欄を有効にする")
    var reply = false

    @Option(help: "replyのplaceholderテキスト (--replyと併用)")
    var replyPlaceholder: String?

    @Option(help: "通知音 (default または名前)")
    var sound: String?

    @Option(help: "添付する画像のパス")
    var image: String?

    mutating func validate() throws {
        if replyPlaceholder != nil, !reply {
            throw ValidationError("--reply-placeholder には --reply の指定が必要です")
        }
    }

    private static func parseTimeout(_ value: String) throws -> Double {
        guard let seconds = Double(value), seconds > 0 else {
            throw ValidationError("--timeout には正の数値を指定してください")
        }
        return seconds
    }

    func makeNotificationRequest() -> NotificationRequest {
        NotificationRequest(
            title: title,
            message: message,
            subtitle: subtitle,
            group: group,
            timeout: timeout,
            actions: action,
            replyEnabled: reply,
            replyPlaceholder: replyPlaceholder,
            sound: sound,
            image: image
        )
    }

    /// 引数パース → 認可 → group置換 → category登録 → 配信 → 応答/タイマー → JSON出力 → 遅延exit
    /// の一連のフローを結線する (design.md System Flows、Requirements 3.6, 8.3)。
    ///
    /// `--profile` 指定時は、NSApplication・UN型に触れる前に対象バンドルのMach-Oへ
    /// ディスパッチする (design.md フローに関する決定、Requirements 10.4, 10.5)。
    func run() throws {
        if let profile {
            ProfileDispatch.dispatch(profile: profile)
            return
        }

        let request = makeNotificationRequest()
        let client = UNNotificationCenterAdapter()
        let delegate = AppDelegate(
            request: request,
            client: client,
            onOutput: { output in
                ExitCoordinator.finish(
                    output,
                    writer: ExitCoordinator.defaultWriter,
                    scheduler: DispatchQueueScheduler.schedule,
                    exit: { Darwin.exit($0) }
                )
            }
        )
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
