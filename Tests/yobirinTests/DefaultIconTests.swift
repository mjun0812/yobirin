import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import yobirin

/// 同梱標準アイコン (`DefaultIcon`) のテスト
/// (design.md Build / Distribution > Installer / IcnsWriter / DefaultIcon、Requirement 11.4)。
final class DefaultIconTests: XCTestCase {
    func testPngDataDecodesAsValidPNGImageOf512x512() throws {
        guard let source = CGImageSourceCreateWithData(DefaultIcon.pngData as CFData, nil) else {
            return XCTFail("DefaultIcon.pngDataが有効な画像としてデコードできなかった")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)

        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return XCTFail("画像プロパティを取得できなかった")
        }
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 512)
    }

    func testPngDataProducesTenSlotIcnsViaIcnsWriter() throws {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-default-icon-tests-\(UUID().uuidString).icns")
            .path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        try IcnsWriter.write(pngData: DefaultIcon.pngData, to: outputPath)

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)
        else {
            return XCTFail("生成したicnsを読み戻せなかった")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
    }
}
