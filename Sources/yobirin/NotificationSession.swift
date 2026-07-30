import Foundation
import UserNotifications
import os

/// yobirinのidentifier規約 (design.md NotificationSessionコード例で確定)。
///
/// - Note: replyのidentifier (`replyActionIdentifier`) はdesign.mdで未規定のため、
///   このタスクで `yobirin-reply` として選定した。
enum NotificationSessionIdentifiers {
    static let categoryIdentifier = "default"
    static let replyActionIdentifier = "yobirin-reply"

    private static let actionIdentifierPrefix = "yobirin-action-"

    static func actionIdentifier(forIndex index: Int) -> String {
        "\(actionIdentifierPrefix)\(index)"
    }

    /// `yobirin-action-<index>` からindexを取り出す。プレフィックス不一致・数値変換不能ならnil。
    static func actionIndex(from identifier: String) -> Int? {
        guard identifier.hasPrefix(actionIdentifierPrefix) else { return nil }
        return Int(identifier.dropFirst(actionIdentifierPrefix.count))
    }
}

/// 通知identifierの生成とgroup置換の走査規則の単一ソース (design.md NotificationIdentity)。
///
/// identifierの組み立てはこのenum以外で行わない。一致の正確さを担保しているのは `#` 終端であり、
/// Base64のアルファベット (`A-Za-z0-9+/=`) が `#` を含まないことから、走査接頭辞
/// `base64(group) + "#"` が別groupの識別名に一致することは構造的に起こり得ない
/// (research.md DD-1。`base64("abc")` が `base64("abcd")` の接頭辞になる場合でも、
/// `#` 終端により識別名としては一致しない)。
enum NotificationIdentity {
    /// group あり: base64(utf8(group)) + "#" + UUID / group なし: UUID
    static func makeIdentifier(group: String?) -> String {
        guard let group else { return UUID().uuidString }
        return replacementPrefix(group: group) + UUID().uuidString
    }

    /// group 置換の走査接頭辞: base64(utf8(group)) + "#"
    static func replacementPrefix(group: String) -> String {
        Data(group.utf8).base64EncodedString() + "#"
    }
}

/// 通知の配信と応答捕捉 (design.md Components and Interfaces > NotificationSession)。
///
/// 結果は「未確定 → 確定 (clicked / dismissed / action / replied / timeout)」の一方向遷移であり、
/// `OSAllocatedUnfairLock` により一度きりの確定を保証する (design.md State Management)。
///
/// `@unchecked Sendable`: `deliver` の group 置換走査が `getDeliveredNotificationIdentifiers` の
/// `@Sendable` completionHandler内で `self` (client呼び出し) を捕捉する必要があるため
/// (design.md Implementation Notes「置換走査の非同期化」)。排他は既存の `committedLock`
/// (`OSAllocatedUnfairLock`) が担っており、この型自体を `Sendable` にしても新たな競合は増えない
/// (`AppFlow` / `DeliveredNotificationSweep` と同じパターン)。
final class NotificationSession: @unchecked Sendable {
    private let client: NotificationCenterClient
    private let actions: [String]
    private let onResult: (NotificationResult) -> Void

    /// true == 既に結果が確定済み。以降の入力は無視する (Requirement 3.8)。
    private let committedLock = OSAllocatedUnfairLock(initialState: false)

    /// `deliver` で配信した通知のidentifier。timeout確定時に削除する対象を特定するために保持する
    /// (Requirement 5.2)。`deliver` は応答処理が始まる前に一度だけ呼ばれる想定のため、
    /// 追加のロックなしで安全に読み書きできる。
    private var deliveredIdentifier: String?

    init(client: NotificationCenterClient, actions: [String], onResult: @escaping (NotificationResult) -> Void) {
        self.client = client
        self.actions = actions
        self.onResult = onResult
    }

    /// category登録・group置換・通知addを行う (Requirements 1.1-1.4, 2.1, 2.2, 4.1, 4.2, 4.4)。
    ///
    /// identifierの採番と`deliveredIdentifier`の設定は同期部分で完了させる (後続の`commit`が
    /// 読むため)。group指定時のみ「配信済み一覧の取得 → 自groupの接頭辞に一致する識別名の抽出
    /// → 削除 → add」の順で置換する (design.md System Flows「identifier規則とgroup置換」、
    /// Requirement 1.1-1.5)。この置換走査により、同一groupの並行プロセスであっても自分が採番した
    /// 識別名以外を削除することはない (yobirin-cli Requirement 5.2の「自分が配信した通知を削除」
    /// への追随)。
    func deliver(_ request: NotificationRequest, completionHandler: (@Sendable (Error?) -> Void)? = nil) throws {
        let content = try Self.makeContent(from: request)
        content.categoryIdentifier = NotificationSessionIdentifiers.categoryIdentifier

        let identifier = NotificationIdentity.makeIdentifier(group: request.group)
        deliveredIdentifier = identifier

        client.setNotificationCategories([
            Self.makeCategory(
                actions: request.actions,
                replyEnabled: request.replyEnabled,
                replyPlaceholder: request.replyPlaceholder
            )
        ])

        // `UNNotificationRequest` は `Sendable` に準拠しないため、group置換走査の
        // completionHandler (`@Sendable`) を跨いで捕捉するには明示的な `unsafe` 注釈が要る。
        // 生成後は不変であり、完了ハンドラは1回しか呼ばれないため実質的に安全 (research.md D3)。
        nonisolated(unsafe) let notificationRequest = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)

        guard let group = request.group else {
            client.add(notificationRequest, completionHandler: completionHandler)
            return
        }

        let prefix = NotificationIdentity.replacementPrefix(group: group)
        client.getDeliveredNotificationIdentifiers { identifiers in
            let ownGroupIdentifiers = identifiers.filter { $0.hasPrefix(prefix) }
            self.client.removeDeliveredNotifications(withIdentifiers: ownGroupIdentifiers)
            self.client.add(notificationRequest, completionHandler: completionHandler)
        }
    }

    /// delegateコールバックからUN型を含まない入力として呼ばれる (design.md 抽象化の境界)。
    /// 既知のidentifierに一致しなければ結果を確定しない (design.mdの `default: break` 準拠)。
    ///
    /// - Parameters:
    ///   - actionIdentifier: `response.actionIdentifier` の値をそのまま渡す。
    ///   - userText: reply応答時のみ `response.userText` を渡す。それ以外はnil。
    func handleResponse(actionIdentifier: String, userText: String?) {
        let result: NotificationResult
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            result = .clicked
        case UNNotificationDismissActionIdentifier:
            result = .dismissed
        case NotificationSessionIdentifiers.replyActionIdentifier:
            guard let userText else { return }
            result = .replied(text: userText)
        default:
            guard let index = NotificationSessionIdentifiers.actionIndex(from: actionIdentifier),
                actions.indices.contains(index)
            else {
                return
            }
            result = .action(label: actions[index], index: index)
        }
        commit(result)
    }

    /// タイムアウト確定への入力。タイマーの起動自体は task 3.1 の範囲。
    func handleTimeout() {
        commit(.timeout)
    }

    /// 一度きりの結果確定 (Requirement 3.8)。先着1件のみが `onResult` を呼び、以降は無視される。
    ///
    /// `result` がtimeoutの場合のみ、配信済み通知を削除してから `onResult` を呼ぶ
    /// (Requirement 5.2: exit後にクリックされ得る通知を残さない)。応答確定時 (clicked等) は
    /// 通知を削除せずそのまま出力を決定する (design.md System Flows)。
    private func commit(_ result: NotificationResult) {
        let shouldEmit = committedLock.withLock { alreadyCommitted -> Bool in
            if alreadyCommitted { return false }
            alreadyCommitted = true
            return true
        }
        guard shouldEmit else { return }
        if case .timeout = result, let identifier = deliveredIdentifier {
            client.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        onResult(result)
    }

    private static func makeCategory(
        actions labels: [String],
        replyEnabled: Bool,
        replyPlaceholder: String?
    ) -> UNNotificationCategory {
        var unActions: [UNNotificationAction] = labels.enumerated().map { index, label in
            UNNotificationAction(
                identifier: NotificationSessionIdentifiers.actionIdentifier(forIndex: index),
                title: label,
                options: []
            )
        }
        if replyEnabled {
            unActions.append(
                UNTextInputNotificationAction(
                    identifier: NotificationSessionIdentifiers.replyActionIdentifier,
                    title: "Reply",
                    options: [],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: replyPlaceholder ?? ""
                )
            )
        }
        return UNNotificationCategory(
            identifier: NotificationSessionIdentifiers.categoryIdentifier,
            actions: unActions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// - Note: `UNNotificationAttachment` の生成はファイルI/Oを伴うため失敗し得る。
    ///   呼び出し元 (`deliver`) が `throws` として伝播し、環境エラーとして扱えるようにする。
    private static func makeContent(from request: NotificationRequest) throws -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.message
        if let subtitle = request.subtitle {
            content.subtitle = subtitle
        }
        if let sound = request.sound {
            content.sound = sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))
        }
        if let image = request.image {
            let url = URL(fileURLWithPath: image)
            let attachment = try UNNotificationAttachment(identifier: UUID().uuidString, url: url, options: nil)
            content.attachments = [attachment]
        }
        return content
    }
}
