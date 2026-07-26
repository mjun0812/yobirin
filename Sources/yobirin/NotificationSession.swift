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

/// 通知の配信と応答捕捉 (design.md Components and Interfaces > NotificationSession)。
///
/// 結果は「未確定 → 確定 (clicked / dismissed / action / replied / timeout)」の一方向遷移であり、
/// `OSAllocatedUnfairLock` により一度きりの確定を保証する (design.md State Management)。
final class NotificationSession {
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
    func deliver(_ request: NotificationRequest, completionHandler: (@Sendable (Error?) -> Void)? = nil) throws {
        let content = try Self.makeContent(from: request)
        content.categoryIdentifier = NotificationSessionIdentifiers.categoryIdentifier

        let identifier = request.group ?? UUID().uuidString
        if request.group != nil {
            client.removeDeliveredNotifications(withIdentifiers: [identifier])
        }

        client.setNotificationCategories([
            Self.makeCategory(
                actions: request.actions,
                replyEnabled: request.replyEnabled,
                replyPlaceholder: request.replyPlaceholder
            )
        ])

        let notificationRequest = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        deliveredIdentifier = identifier
        client.add(notificationRequest, completionHandler: completionHandler)
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
