import Foundation

/// テスト共通のフィクスチャ。
enum TestSupport {
    /// `--image` の検証 (Requirements 9.1, 9.2) を通る、実在するPNGのパスを返す。
    ///
    /// 検証が入る前は `/tmp/icon.png` のような存在しないパスをそのまま渡せたが、現在は
    /// 通知の配信前に存在と拡張子を確認するため、実体が必要になる。
    ///
    /// 同じパスを使い回し、存在しないときだけ作る。中身は参照されない (拡張子と存在のみ検証)
    /// ため、PNGシグネチャの4バイトで足りる。テストごとの削除は行わない — 一時領域の
    /// 数バイトであり、並行実行しても衝突しない。
    static func existingImagePath() -> String {
        let path = NSTemporaryDirectory() + "yobirin-test-fixture-icon.png"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        }
        return path
    }
}
