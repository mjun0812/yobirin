import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import yobirin

/// icns生成 (`IcnsWriter`) のテスト
/// (design.md Build / Distribution > Installer / IcnsWriter / DefaultIcon、Requirements 11.3, 11.4)。
final class IcnsWriterTests: XCTestCase {
    /// ピクセルサイズとDPIの組。DPIメタデータ欠落による退行 (10スロット→5スロット) を
    /// 検知するため、順序に依存しない集合として比較する。
    private struct PixelDPIPair: Hashable {
        let pixelSize: Int
        let dpi: Int
    }

    private func temporaryPath(extension ext: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yobirin-icns-writer-tests-\(UUID().uuidString).\(ext)")
            .path
    }

    /// 16x16の単色PNGをテスト用の元画像として生成する (外部ファイルに依存しない)。
    private func makeTestPNGData() -> Data {
        let size = 16
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testGeneratesTenSlotsWithDistinctPixelSizeAndDPIPairs() throws {
        let outputPath = temporaryPath(extension: "icns")
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        try IcnsWriter.write(pngData: makeTestPNGData(), to: outputPath)

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)
        else {
            return XCTFail("生成したicnsを読み戻せなかった")
        }
        let count = CGImageSourceGetCount(source)
        XCTAssertEqual(count, 10)

        let pairs = Set(
            (0..<count).map { index -> PixelDPIPair in
                let properties =
                    CGImageSourceCopyPropertiesAtIndex(source, index, nil) as! [CFString: Any]
                let pixelSize = properties[kCGImagePropertyPixelWidth] as! Int
                let dpi = properties[kCGImagePropertyDPIWidth] as! Double
                return PixelDPIPair(pixelSize: pixelSize, dpi: Int(dpi.rounded()))
            })

        let expected = Set(
            [16, 32, 128, 256, 512].flatMap { size in
                [
                    PixelDPIPair(pixelSize: size, dpi: 72),
                    PixelDPIPair(pixelSize: size * 2, dpi: 144),
                ]
            })

        XCTAssertEqual(pairs, expected)
    }

    func testInvalidPNGDataThrowsInvalidImageData() {
        let outputPath = temporaryPath(extension: "icns")
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        XCTAssertThrowsError(
            try IcnsWriter.write(pngData: Data([0x00, 0x01, 0x02]), to: outputPath)
        ) { error in
            XCTAssertEqual(error as? IcnsWriter.WriterError, .invalidImageData)
        }
    }

    func testUnreadablePathThrowsUnreadableSource() {
        let missingPath = temporaryPath(extension: "png")
        let outputPath = temporaryPath(extension: "icns")
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        XCTAssertThrowsError(
            try IcnsWriter.write(contentsOfFile: missingPath, to: outputPath)
        ) { error in
            XCTAssertEqual(error as? IcnsWriter.WriterError, .unreadableSource(path: missingPath))
        }
    }
}
