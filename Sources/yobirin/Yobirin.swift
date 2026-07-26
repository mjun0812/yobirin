import ArgumentParser

@main
struct YobirinCommand: ParsableCommand {
    @Option(help: "通知のタイトル")
    var title: String

    @Option(help: "通知の本文")
    var message: String

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

    func run() throws {}
}
