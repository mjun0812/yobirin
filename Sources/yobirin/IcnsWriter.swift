import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIOでPNGからicnsを生成する
/// (design.md Build / Distribution > Installer / IcnsWriter / DefaultIcon、Requirements 11.3, 11.4)。
///
/// icnsの10スロット (16/32/128/256/512の各1x/2x) は、各画像にDPIメタデータ (1x=72 / 2x=144) を
/// 付与しないと成立しない。付与しない場合、同一ピクセルサイズが衝突するスロット
/// (例: 16pt@2x=32px と 32pt@1x=32px) のどちらかが破棄され、10スロットが5スロットへ劣化する
/// (research.md「CLIインストールとバンドル外実行の実測」で実測済み)。
enum IcnsWriter {
    enum WriterError: Error, Equatable {
        /// PNGとして解釈できない入力データ。
        case invalidImageData
        /// 指定パスから画像を読み込めなかった。
        case unreadableSource(path: String)
        /// icns書き出し先の作成に失敗した。
        case destinationCreationFailed(path: String)
        /// リサイズ処理に失敗した。
        case resizeFailed(pixelSize: Int)
        /// icnsの書き出し (finalize) に失敗した。
        case writeFailed
    }

    /// 1スロット (nominalSizeはpt換算のアイコンサイズ、scaleは1x/2x)。
    private struct Slot {
        let nominalSize: Int
        let scale: Int
        var pixelSize: Int { nominalSize * scale }
        var dpi: CGFloat { scale == 1 ? 72 : 144 }
    }

    /// icnsの10スロット (16/32/128/256/512の各1x/2x)。
    private static let slots: [Slot] = [16, 32, 128, 256, 512].flatMap {
        [Slot(nominalSize: $0, scale: 1), Slot(nominalSize: $0, scale: 2)]
    }

    /// PNGの`Data`を元画像としてicnsを生成し、`outputPath`へ書き出す。
    static func write(pngData: Data, to outputPath: String) throws {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw WriterError.invalidImageData
        }
        try write(image: image, to: outputPath)
    }

    /// 元画像のパスからicnsを生成し、`outputPath`へ書き出す。
    static func write(contentsOfFile path: String, to outputPath: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw WriterError.unreadableSource(path: path)
        }
        try write(image: image, to: outputPath)
    }

    private static func write(image: CGImage, to outputPath: String) throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.icns.identifier as CFString, slots.count, nil)
        else {
            throw WriterError.destinationCreationFailed(path: outputPath)
        }

        for slot in slots {
            guard let resized = resize(image, to: slot.pixelSize) else {
                throw WriterError.resizeFailed(pixelSize: slot.pixelSize)
            }
            let properties =
                [
                    kCGImagePropertyDPIWidth: slot.dpi,
                    kCGImagePropertyDPIHeight: slot.dpi,
                ] as CFDictionary
            CGImageDestinationAddImage(destination, resized, properties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw WriterError.writeFailed
        }
    }

    /// CoreGraphicsで正方形へリサイズする (外部コマンドは使わない)。
    private static func resize(_ image: CGImage, to pixelSize: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        return context.makeImage()
    }
}
