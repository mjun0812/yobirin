import XCTest

@testable import yobirin

final class NotifyCommandTests: XCTestCase {
    // MARK: - Required options

    func testParsesWithNoArgumentsFails() throws {
        XCTAssertThrowsError(try NotifyCommand.parse([]))
    }

    func testMissingTitleFails() throws {
        XCTAssertThrowsError(try NotifyCommand.parse(["--message", "body"]))
    }

    func testMissingMessageFails() throws {
        XCTAssertThrowsError(try NotifyCommand.parse(["--title", "hello"]))
    }

    func testParsesRequiredOptionsOnly() throws {
        let command = try NotifyCommand.parse(["--title", "hello", "--message", "body"])

        XCTAssertEqual(command.title, "hello")
        XCTAssertEqual(command.message, "body")
        XCTAssertNil(command.profile)
        XCTAssertNil(command.subtitle)
        XCTAssertNil(command.group)
        XCTAssertNil(command.timeout)
        XCTAssertEqual(command.action, [])
        XCTAssertFalse(command.reply)
        XCTAssertNil(command.replyPlaceholder)
        XCTAssertNil(command.sound)
        XCTAssertNil(command.image)
    }

    // MARK: - Individual options

    func testParsesSubtitle() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--subtitle", "sub"])
        XCTAssertEqual(command.subtitle, "sub")
    }

    func testParsesProfile() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--profile", "claude"])
        XCTAssertEqual(command.profile, "claude")
    }

    func testParsesWithoutProfileDefaultsToNil() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m"])
        XCTAssertNil(command.profile)
    }

    func testParsesGroup() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--group", "build"])
        XCTAssertEqual(command.group, "build")
    }

    func testParsesTimeout() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--timeout", "5"])
        XCTAssertEqual(command.timeout, 5)
    }

    func testTimeoutZeroFails() throws {
        XCTAssertThrowsError(try NotifyCommand.parse(["--title", "t", "--message", "m", "--timeout", "0"]))
    }

    func testTimeoutNegativeFails() throws {
        // "--timeout" "-1" (スペース区切り) だとswift-argument-parserが "-1" をオプションらしき
        // トークンとみなし、自前のparseTimeoutに到達する前に "Missing value" で弾いてしまう。
        // "=" 構文にすることで確実にparseTimeoutのバリデーションを経由させる。
        XCTAssertThrowsError(try NotifyCommand.parse(["--title", "t", "--message", "m", "--timeout=-1"]))
    }

    func testTimeoutNonNumericFails() throws {
        XCTAssertThrowsError(try NotifyCommand.parse(["--title", "t", "--message", "m", "--timeout", "abc"]))
    }

    func testParsesMultipleActions() throws {
        let command = try NotifyCommand.parse([
            "--title", "t", "--message", "m",
            "--action", "Open", "--action", "Dismiss",
        ])
        XCTAssertEqual(command.action, ["Open", "Dismiss"])
    }

    func testParsesNoActions() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m"])
        XCTAssertEqual(command.action, [])
    }

    func testParsesReplyWithoutPlaceholder() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--reply"])
        XCTAssertTrue(command.reply)
        XCTAssertNil(command.replyPlaceholder)
    }

    func testParsesReplyWithPlaceholder() throws {
        let command = try NotifyCommand.parse([
            "--title", "t", "--message", "m",
            "--reply", "--reply-placeholder", "返信を入力",
        ])
        XCTAssertTrue(command.reply)
        XCTAssertEqual(command.replyPlaceholder, "返信を入力")
    }

    func testReplyPlaceholderWithoutReplyFails() throws {
        XCTAssertThrowsError(
            try NotifyCommand.parse([
                "--title", "t", "--message", "m",
                "--reply-placeholder", "返信を入力",
            ])
        )
    }

    func testParsesSound() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--sound", "default"])
        XCTAssertEqual(command.sound, "default")
    }

    func testParsesImage() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--image", "/tmp/icon.png"])
        XCTAssertEqual(command.image, "/tmp/icon.png")
    }

    func testIconOptionIsNotProvided() throws {
        XCTAssertThrowsError(
            try NotifyCommand.parse(["--title", "t", "--message", "m", "--icon", "x"])
        )
    }

    // MARK: - NotificationRequest conversion

    func testMakeNotificationRequestReflectsAllOptions() throws {
        let command = try NotifyCommand.parse([
            "--title", "t", "--message", "m",
            "--subtitle", "sub",
            "--group", "build",
            "--timeout", "5",
            "--action", "Open", "--action", "Dismiss",
            "--reply", "--reply-placeholder", "返信を入力",
            "--sound", "default",
            "--image", "/tmp/icon.png",
        ])
        let request = command.makeNotificationRequest()

        XCTAssertEqual(request.title, "t")
        XCTAssertEqual(request.message, "m")
        XCTAssertEqual(request.subtitle, "sub")
        XCTAssertEqual(request.group, "build")
        XCTAssertEqual(request.timeout, 5)
        XCTAssertEqual(request.actions, ["Open", "Dismiss"])
        XCTAssertTrue(request.replyEnabled)
        XCTAssertEqual(request.replyPlaceholder, "返信を入力")
        XCTAssertEqual(request.sound, "default")
        XCTAssertEqual(request.image, "/tmp/icon.png")
    }

    func testMakeNotificationRequestWithOnlyRequiredOptions() throws {
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m"])
        let request = command.makeNotificationRequest()

        XCTAssertEqual(request.title, "t")
        XCTAssertEqual(request.message, "m")
        XCTAssertNil(request.subtitle)
        XCTAssertNil(request.group)
        XCTAssertNil(request.timeout)
        XCTAssertEqual(request.actions, [])
        XCTAssertFalse(request.replyEnabled)
        XCTAssertNil(request.replyPlaceholder)
        XCTAssertNil(request.sound)
        XCTAssertNil(request.image)
    }
}
