import Foundation
import XCTest

@testable import yobirin

/// 引き継ぎ先バンドルとのバージョン比較 (design.md 透過ディスパッチの詳細、Requirement 17.4)。
///
/// テンポラリ領域に偽バンドル (Info.plistのみ) を構成して検証する。実 `~/Applications` へは
/// 一切触れない。
final class BundleVersionCheckTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-version-check-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    /// `<tempRoot>/Yobirin.app` を偽バンドルとして組み立てる。`version` が `nil` ならInfo.plist
    /// に `CFBundleShortVersionString` キー自体を含めない (欠損の再現)。
    private func makeFakeBundle(version: String?) -> String {
        let bundleDir = tempRoot.appendingPathComponent("Yobirin.app")
        let contentsDir = bundleDir.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        var plist: [String: Any] = [:]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try! data.write(to: contentsDir.appendingPathComponent("Info.plist"))
        return bundleDir.path
    }

    func testSameVersionReturnsNilWithoutNotice() {
        let bundlePath = makeFakeBundle(version: "0.4.1")

        XCTAssertNil(BundleVersionCheck.updateNotice(bundlePath: bundlePath, currentVersion: "0.4.1"))
    }

    func testDifferentVersionReturnsUpdateNoticeMentioningBothVersionsAndInstallCommand() {
        let bundlePath = makeFakeBundle(version: "0.4.0")

        let notice = BundleVersionCheck.updateNotice(bundlePath: bundlePath, currentVersion: "0.4.1")

        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("0.4.0"))
        XCTAssertTrue(notice!.contains("0.4.1"))
        XCTAssertTrue(notice!.contains("yobirin install"))
    }

    func testMissingVersionKeyIsTreatedAsIncomparableAndReturnsNil() {
        let bundlePath = makeFakeBundle(version: nil)

        XCTAssertNil(BundleVersionCheck.updateNotice(bundlePath: bundlePath, currentVersion: "0.4.1"))
    }

    func testMissingInfoPlistIsTreatedAsIncomparableAndReturnsNil() {
        let bundlePath = tempRoot.appendingPathComponent("Missing.app").path

        XCTAssertNil(BundleVersionCheck.updateNotice(bundlePath: bundlePath, currentVersion: "0.4.1"))
    }
}
