import UserNotifications
import XCTest

@testable import yobirin

/// `UNNotificationCenterAdapter` の遅延評価化を検証する (design.md
/// 「NotificationCenterClientのcenterは遅延評価へ修正」、Requirement 12.1)。
///
/// - Note (RED phase evidence): 修正前の `UNNotificationCenterAdapter` は
///   `private let center = UNUserNotificationCenter.current()` という非lazyな格納プロパティを持ち、
///   `init()` の時点で `UNUserNotificationCenter.current()` へ到達していた。素のMach-O
///   (署名済み.appバンドル外。swift testの実行環境はこれに該当する) では
///   `bundleProxyForCurrentProcess is nil` によりSIGABRTでプロセスごと落ちるため、
///   本テストは修正前は失敗ではなくクラッシュとして観測される
///   (`swift test --filter NotificationCenterClientTests` 実行時にテストプロセスがSIGABRTで終了する)。
final class NotificationCenterClientTests: XCTestCase {
    func testAdapterCanBeInstantiatedOutsideABundleWithoutCrashing() {
        // インスタンス化だけでは `UNUserNotificationCenter.current()` に到達しないこと
        // (型に触れただけではセンターへアクセスしない遅延評価) を確認する。
        let adapter: NotificationCenterClient = UNNotificationCenterAdapter()

        XCTAssertTrue(adapter is UNNotificationCenterAdapter)
    }
}
