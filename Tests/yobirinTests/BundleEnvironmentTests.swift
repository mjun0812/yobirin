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

    // MARK: - reExecTarget (symlink経由起動の実体パス再exec判定)
    //
    // CFBundleはsymlinkを解決しないため、`~/.local/bin/yobirin` (symlink) 経由のexecでは
    // バンドル内実体を指していても `Bundle.main.bundleIdentifier` がnilになる (実測。
    // 直接実行では解決される)。この場合は実体パスへ再execして直接実行と同一条件に正規化する。

    func testReExecTargetWhenBundleIdentifierResolvedReturnsNil() {
        // バンドルが解決済みなら、パスが異なっても再execは不要。
        XCTAssertNil(
            BundleEnvironment.reExecTarget(
                bundleIdentifier: "com.mjun0812.yobirin",
                executablePath: "/Users/u/.local/bin/yobirin",
                resolvedExecutablePath: "/Users/u/Applications/Yobirin.app/Contents/MacOS/yobirin"
            )
        )
    }

    func testReExecTargetWhenExecutablePathIsAlreadyResolvedReturnsNil() {
        // 素のバイナリ直接実行 (realpath一致): 再execしても状況は変わらないので不要。
        let path = "/Users/u/Downloads/yobirin"
        XCTAssertNil(
            BundleEnvironment.reExecTarget(
                bundleIdentifier: nil,
                executablePath: path,
                resolvedExecutablePath: path
            )
        )
    }

    func testReExecTargetWhenSymlinkLaunchReturnsResolvedPath() {
        // symlink経由起動 (Bundle未解決 + realpath不一致) → 実体パスへ再exec。
        let resolved = "/Users/u/Applications/Yobirin.app/Contents/MacOS/yobirin"
        XCTAssertEqual(
            BundleEnvironment.reExecTarget(
                bundleIdentifier: nil,
                executablePath: "/Users/u/.local/bin/yobirin",
                resolvedExecutablePath: resolved
            ),
            resolved
        )
    }

    // MARK: - readBundleInfo (ListCommandとBundleVersionCheckが共有する読み取り経路、Requirements 14.2, 17.4)

    func testReadBundleInfoReturnsBundleIDAndVersionFromInfoPlist() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-bundle-info-tests-\(UUID().uuidString)")
        let contentsDir = tempDir.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.mjun0812.yobirin",
            "CFBundleShortVersionString": "0.4.1",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsDir.appendingPathComponent("Info.plist"))

        let info = BundleEnvironment.readBundleInfo(bundlePath: tempDir.path)

        XCTAssertEqual(info.bundleID, "com.mjun0812.yobirin")
        XCTAssertEqual(info.version, "0.4.1")
    }

    func testReadBundleInfoReturnsNilForBothWhenInfoPlistIsMissing() {
        let info = BundleEnvironment.readBundleInfo(bundlePath: "/nonexistent/Yobirin.app")

        XCTAssertNil(info.bundleID)
        XCTAssertNil(info.version)
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
