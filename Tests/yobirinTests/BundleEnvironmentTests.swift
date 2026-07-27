import Foundation
import XCTest

@testable import yobirin

/// バンドル内/外の判定ヘルパ (design.md CLIとアプリの二面性、Requirement 12.1)。
/// 起動ゲート本体への配線は task 6.3 の範囲であり、ここではヘルパ単体の挙動を検証する。
final class BundleEnvironmentTests: XCTestCase {
    func testIsOutsideBundleWhenBundleIdentifierIsNilReturnsTrue() {
        XCTAssertTrue(BundleEnvironment.isOutsideBundle(bundleIdentifier: nil))
    }

    func testIsOutsideBundleWhenBundleIdentifierIsPresentReturnsFalse() {
        XCTAssertFalse(BundleEnvironment.isOutsideBundle(bundleIdentifier: "com.mjun0812.yobirin"))
    }

    func testIsOutsideBundleDefaultArgumentReadsBundleMainBundleIdentifier() {
        // 既定引数が実際の `Bundle.main.bundleIdentifier` に委譲していることを検証する。
        // xctestホストプロセス自体が独自のbundleIdentifier ("com.apple.dt.xctest.tool") を
        // 持つため、ここでの結果 (true/false) はホスト環境依存であり決め打ちしない
        // (CONCERNSに記録: `UNUserNotificationCenter.current()` が例外死する条件
        // 「bundleProxyForCurrentProcess is nil」とは別の判定であり、swift testの実行環境では
        // 両者が一致しない)。
        XCTAssertEqual(BundleEnvironment.isOutsideBundle(), Bundle.main.bundleIdentifier == nil)
    }
}
