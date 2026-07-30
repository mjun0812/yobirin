import ArgumentParser
import XCTest

@testable import yobirin

/// ルートコマンドのサブコマンド解決を検証する (design.md CLI契約、Requirement 11.8)。
/// 従来形式 `yobirin --title <str> --message <str> ...` が既定サブコマンド `NotifyCommand` へ
/// そのまま解決されることを確認する。
final class YobirinCommandTests: XCTestCase {
    func testDefaultSubcommandResolvesToNotifyCommandWithAllOptions() throws {
        let parsed = try YobirinCommand.parseAsRoot([
            "--title", "t", "--message", "m",
            "--subtitle", "sub",
            "--group", "build",
            "--timeout", "5",
            "--action", "Open", "--action", "Dismiss",
            "--reply", "--reply-placeholder", "返信を入力",
            "--sound", "default",
            "--image", TestSupport.existingImagePath(),
        ])

        guard let notify = parsed as? NotifyCommand else {
            XCTFail("従来形式の引数はNotifyCommandへ解決されるべき")
            return
        }

        XCTAssertEqual(notify.title, "t")
        XCTAssertEqual(notify.message, "m")
        XCTAssertEqual(notify.subtitle, "sub")
        XCTAssertEqual(notify.group, "build")
        XCTAssertEqual(notify.timeout, 5)
        XCTAssertEqual(notify.action, ["Open", "Dismiss"])
        XCTAssertTrue(notify.reply)
        XCTAssertEqual(notify.replyPlaceholder, "返信を入力")
        XCTAssertEqual(notify.sound, "default")
        XCTAssertEqual(notify.image, TestSupport.existingImagePath())
    }

    func testListSubcommandResolvesToListCommand() throws {
        let parsed = try YobirinCommand.parseAsRoot(["list"])

        guard parsed is ListCommand else {
            XCTFail("\"list\" はListCommandへ解決されるべき")
            return
        }
    }

    func testPsSubcommandResolvesToPsCommand() throws {
        let parsed = try YobirinCommand.parseAsRoot(["ps"])

        guard parsed is PsCommand else {
            XCTFail("\"ps\" はPsCommandへ解決されるべき")
            return
        }
    }

    func testDefaultSubcommandResolvesToNotifyCommandWithRequiredOptionsOnly() throws {
        let parsed = try YobirinCommand.parseAsRoot(["--title", "hello", "--message", "body"])

        guard let notify = parsed as? NotifyCommand else {
            XCTFail("従来形式の引数はNotifyCommandへ解決されるべき")
            return
        }

        XCTAssertEqual(notify.title, "hello")
        XCTAssertEqual(notify.message, "body")
        XCTAssertNil(notify.subtitle)
        XCTAssertNil(notify.group)
        XCTAssertNil(notify.timeout)
        XCTAssertEqual(notify.action, [])
        XCTAssertFalse(notify.reply)
        XCTAssertNil(notify.replyPlaceholder)
        XCTAssertNil(notify.sound)
        XCTAssertNil(notify.image)
    }
}

// MARK: - サブコマンドの登録と説明 (Requirements 7.1, 7.4)

final class YobirinCommandRegistrationTests: XCTestCase {
    func testCompletionSubcommandIsRegistered() throws {
        XCTAssertTrue(try YobirinCommand.parseAsRoot(["completion", "zsh"]) is CompletionCommand)
    }

    func testSweepSubcommandIsRegistered() throws {
        XCTAssertTrue(try YobirinCommand.parseAsRoot(["sweep"]) is SweepCommand)
    }

    func testDoctorSubcommandIsRegistered() throws {
        XCTAssertTrue(try YobirinCommand.parseAsRoot(["doctor"]) is DoctorCommand)
    }

    /// ヘルプ一覧に説明のないサブコマンドを残さない。
    func testEverySubcommandHasAnAbstract() throws {
        for subcommand in YobirinCommand.configuration.subcommands {
            XCTAssertFalse(
                subcommand.configuration.abstract.isEmpty,
                "\(subcommand.configuration.commandName ?? "\(subcommand)") に abstract が無い")
        }
    }

    func testRootCommandHasAnAbstract() throws {
        XCTAssertFalse(YobirinCommand.configuration.abstract.isEmpty)
    }

    /// 表示文言は英語 (structure.md の既定)。ASCII外の文字が混ざっていないことで確認する。
    ///
    /// - Note: `subcommands.map(\.configuration.abstract)` と書くと Swift 6.3.3 の
    ///   SIL 生成がクラッシュする (existential metatype への key path)。for ループで回避する。
    func testAbstractsAreWrittenInEnglish() throws {
        var abstracts = [YobirinCommand.configuration.abstract]
        for subcommand in YobirinCommand.configuration.subcommands {
            abstracts.append(subcommand.configuration.abstract)
        }

        for abstract in abstracts {
            XCTAssertTrue(abstract.allSatisfy { $0.isASCII }, "英語以外の文字が含まれている: \(abstract)")
        }
    }
}
