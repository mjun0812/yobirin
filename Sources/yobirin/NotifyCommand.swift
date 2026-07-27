import AppKit
import ArgumentParser
import Foundation

/// 通知送信の既定サブコマンド (design.md CLI契約、Requirements 1, 2, 4, 5)。
/// ルートコマンド (`YobirinCommand`) の `defaultSubcommand` に指定され、従来の
/// `yobirin --title <str> --message <str> ...` 形式はそのままこのサブコマンドへ解決される
/// (Requirement 11.8)。
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notify")

    @Option(help: "The notification title")
    var title: String

    @Option(help: "The notification body")
    var message: String

    @Option(help: "Deliver via the bundle of the specified profile")
    var profile: String?

    @Option(help: "The notification subtitle")
    var subtitle: String?

    @Option(help: "Group ID; replaces an existing notification with the same group")
    var group: String?

    @Option(
        help: "Seconds to wait for a response (waits forever when omitted); positive numbers only",
        transform: Self.parseTimeout)
    var timeout: Double?

    @Option(help: "Action button label (repeatable)")
    var action: [String] = []

    @Flag(help: "Enable the text reply field")
    var reply = false

    @Option(help: "Placeholder text for the reply field (requires --reply)")
    var replyPlaceholder: String?

    @Option(help: "Notification sound ('default' or a sound name)")
    var sound: String?

    @Option(help: "Path of an image to attach")
    var image: String?

    mutating func validate() throws {
        if replyPlaceholder != nil, !reply {
            throw ValidationError("--reply-placeholder requires --reply")
        }
    }

    private static func parseTimeout(_ value: String) throws -> Double {
        guard let seconds = Double(value), seconds > 0 else {
            throw ValidationError("--timeout must be a positive number")
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
