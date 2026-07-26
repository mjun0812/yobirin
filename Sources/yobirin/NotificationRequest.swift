/// パース済みCLIオプションから組み立てる通知リクエスト。
///
/// - Note: `--icon` に相当するフィールドは存在しない (アイコンはビルド時にバンドルへ焼き込むため)。
struct NotificationRequest {
    var title: String
    var message: String
    var subtitle: String?
    var group: String?
    var timeout: Double?
    var actions: [String]
    var replyEnabled: Bool
    var replyPlaceholder: String?
    var sound: String?
    var image: String?
}
