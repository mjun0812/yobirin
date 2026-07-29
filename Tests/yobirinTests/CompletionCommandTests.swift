import ArgumentParser
import XCTest

@testable import yobirin

final class CompletionCommandTests: XCTestCase {
    // MARK: - 受け付けるシェル (Requirement 8.2)

    func testAcceptsSupportedShells() throws {
        let expected: [(String, CompletionShell)] = [
            ("bash", .bash),
            ("zsh", .zsh),
            ("fish", .fish),
        ]

        for (argument, shell) in expected {
            XCTAssertNoThrow(try CompletionCommand.parse([argument]), "\(argument) を受理していない")
            XCTAssertEqual(try CompletionCommand.parseShell(argument), shell, "\(argument) を解釈できていない")
        }
    }

    // MARK: - 未対応のシェル (Requirement 8.3)

    func testRejectsUnsupportedShell() throws {
        XCTAssertThrowsError(try CompletionCommand.parse(["powershell"]))
    }

    func testRejectsMissingShellArgument() throws {
        XCTAssertThrowsError(try CompletionCommand.parse([]))
    }

    /// ヘルプとエラー文言に候補が並ぶよう、受理可能な値が列挙できること。
    func testAdvertisesAllSupportedShells() throws {
        let list = CompletionCommand.supportedShellList
        for shell in ["bash", "zsh", "fish"] {
            XCTAssertTrue(list.contains(shell), "\(shell) が候補に無い: \(list)")
        }
    }

    /// 拒否時の文言が、何を渡せばよいかを示すこと。
    func testRejectionMessageListsSupportedShells() throws {
        XCTAssertThrowsError(try CompletionCommand.parseShell("powershell")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("powershell"), message)
            XCTAssertTrue(message.contains("zsh"), message)
        }
    }

    // MARK: - スクリプトの出力 (Requirement 8.1)

    func testWritesCompletionScriptForEachShell() throws {
        for shell in CompletionShell.allCases {
            var written: [String] = []
            CompletionCommand.perform(shell: shell, stdoutWriter: { written.append($0) })

            XCTAssertEqual(written.count, 1, "\(shell.rawValue) で1回だけ書き込まれていない")
            XCTAssertFalse(written.first?.isEmpty ?? true, "\(shell.rawValue) のスクリプトが空")
        }
    }

    /// 生成をライブラリへ委譲していること (自前生成に差し替わっていないこと) を、
    /// シェル固有のマーカーで確認する。
    func testGeneratedScriptTargetsTheRequestedShell() throws {
        var zshScript = ""
        CompletionCommand.perform(shell: .zsh, stdoutWriter: { zshScript = $0 })
        XCTAssertTrue(zshScript.contains("#compdef"), "zsh向けの補完スクリプトになっていない")

        var fishScript = ""
        CompletionCommand.perform(shell: .fish, stdoutWriter: { fishScript = $0 })
        XCTAssertTrue(fishScript.contains("complete"), "fish向けの補完スクリプトになっていない")
    }

    /// ルートコマンド名で補完が定義されること (サブコマンド自身の名前ではない)。
    func testCompletionTargetsTheRootCommand() throws {
        var script = ""
        CompletionCommand.perform(shell: .zsh, stdoutWriter: { script = $0 })
        XCTAssertTrue(script.contains("yobirin"))
    }
}
