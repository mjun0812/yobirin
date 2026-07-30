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
        let imagePath = TestSupport.existingImagePath()
        let command = try NotifyCommand.parse(["--title", "t", "--message", "m", "--image", imagePath])
        XCTAssertEqual(command.image, imagePath)
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
            "--image", TestSupport.existingImagePath(),
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
        XCTAssertEqual(request.image, TestSupport.existingImagePath())
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

// MARK: - 短縮フラグ (Requirements 6.1, 6.2, 6.3, 6.5)

final class NotifyCommandShortFlagTests: XCTestCase {
    func testShortFlagsProduceTheSameRequestAsLongOptions() throws {
        let short = try NotifyCommand.parse(["-t", "Deploy", "-m", "Release?", "-p", "claude", "-a", "Yes"])
        let long = try NotifyCommand.parse([
            "--title", "Deploy", "--message", "Release?", "--profile", "claude", "--action", "Yes",
        ])

        XCTAssertEqual(short.title, long.title)
        XCTAssertEqual(short.message, long.message)
        XCTAssertEqual(short.profile, long.profile)
        XCTAssertEqual(short.action, long.action)
    }

    func testRepeatedShortActionPreservesOrder() throws {
        let command = try NotifyCommand.parse(["-t", "t", "-m", "m", "-a", "Approve", "-a", "Reject"])
        XCTAssertEqual(command.action, ["Approve", "Reject"])
    }

    func testShortAndLongFormsCanBeMixed() throws {
        let command = try NotifyCommand.parse(["-t", "t", "--message", "m", "-p", "codex"])
        XCTAssertEqual(command.title, "t")
        XCTAssertEqual(command.message, "m")
        XCTAssertEqual(command.profile, "codex")
    }

    func testEqualsSeparatedShortFormIsAccepted() throws {
        let command = try NotifyCommand.parse(["-t=t", "-m=m", "-p=claude"])
        XCTAssertEqual(command.title, "t")
        XCTAssertEqual(command.message, "m")
        XCTAssertEqual(command.profile, "claude")
    }

    /// 値の結合表記は受理しない。受理すると `ProfileDispatch` の除去が不完全になり、
    /// 引き継ぎ先で再ディスパッチが起きて exec が無限ループする (research.md F2)。
    func testJoinedShortFormIsRejected() throws {
        XCTAssertThrowsError(try NotifyCommand.parse(["-tTitle", "-m", "m"]))
        XCTAssertThrowsError(try NotifyCommand.parse(["-t", "t", "-m", "m", "-pclaude"]))
    }

    /// 既存のロング形式はすべて引き続き受理する (Requirement 6.5)。
    func testAllLongOptionsAreStillAccepted() throws {
        let command = try NotifyCommand.parse([
            "--title", "t", "--message", "m",
            "--profile", "claude", "--subtitle", "sub", "--group", "build",
            "--timeout", "5", "--action", "Open",
            "--reply", "--reply-placeholder", "hint",
            "--sound", "default", "--image", TestSupport.existingImagePath(),
        ])

        XCTAssertEqual(command.title, "t")
        XCTAssertEqual(command.profile, "claude")
        XCTAssertEqual(command.subtitle, "sub")
        XCTAssertEqual(command.group, "build")
        XCTAssertEqual(command.timeout, 5)
        XCTAssertEqual(command.action, ["Open"])
        XCTAssertTrue(command.reply)
        XCTAssertEqual(command.replyPlaceholder, "hint")
        XCTAssertEqual(command.sound, "default")
        XCTAssertEqual(command.image, TestSupport.existingImagePath())
    }
}

// MARK: - 単位付きタイムアウト (Requirements 4.1〜4.6)

final class NotifyCommandTimeoutTests: XCTestCase {
    private func timeout(_ value: String) throws -> Double? {
        try NotifyCommand.parse(["-t", "t", "-m", "m", "--timeout", value]).timeout
    }

    func testBareNumberIsStillSeconds() throws {
        XCTAssertEqual(try timeout("300"), 300)
        XCTAssertEqual(try timeout("0.5"), 0.5)
    }

    func testUnitSuffixesAreConvertedToSeconds() throws {
        XCTAssertEqual(try timeout("90s"), 90)
        XCTAssertEqual(try timeout("5m"), 300)
        XCTAssertEqual(try timeout("1h"), 3600)
    }

    func testConcatenatedUnitsAreSummed() throws {
        XCTAssertEqual(try timeout("1h30m"), 5400)
    }

    func testUnparsableValueIsRejected() throws {
        XCTAssertThrowsError(try timeout("abc"))
        XCTAssertThrowsError(try timeout("5x"))
    }

    func testNonPositiveValueIsRejected() throws {
        XCTAssertThrowsError(try timeout("0"))
        XCTAssertThrowsError(try timeout("-5"))
        XCTAssertThrowsError(try timeout("0m"))
    }

    func testOmittedTimeoutWaitsForever() throws {
        XCTAssertNil(try NotifyCommand.parse(["-t", "t", "-m", "m"]).timeout)
    }

    /// 拒否時の文言は、何を渡せばよいかを示す (design.md Error Handling)。
    func testRejectionMessageShowsAcceptedFormats() throws {
        XCTAssertThrowsError(try timeout("abc")) { error in
            let message = NotifyCommand.message(for: error)
            XCTAssertTrue(message.contains("5m") || message.contains("1h30m"), message)
        }
    }

    /// 変換規則は `ps` と共有する単一の定義を使う (Requirement 14.4)。
    func testConversionMatchesTheSharedRule() throws {
        for value in ["300", "90s", "5m", "1h30m"] {
            XCTAssertEqual(try timeout(value), TimeoutDuration.seconds(from: value), value)
        }
    }
}

// MARK: - 標準入力からの本文 (Requirements 5.1〜5.5)

final class NotifyCommandStandardInputTests: XCTestCase {
    /// `parse()` は `validate()` を実行し、`validate()` は標準入力が端末かを見る。
    /// `-m -` を直接パースすると、端末から `swift test` を走らせたときだけ失敗する
    /// 環境依存のテストになる。パース後に本文だけ差し替えて依存を断つ。
    private func command(message: String) throws -> NotifyCommand {
        var parsed = try NotifyCommand.parse(["-t", "t", "-m", "placeholder"])
        parsed.message = message
        return parsed
    }

    func testHyphenMessageReadsFromStandardInput() throws {
        let request = try command(message: "-").makeNotificationRequest(readStandardInput: { "piped body" })
        XCTAssertEqual(request.message, "piped body")
    }

    func testTrailingNewlineIsStripped() throws {
        let request = try command(message: "-").makeNotificationRequest(readStandardInput: { "line\n" })
        XCTAssertEqual(request.message, "line")
    }

    func testAllTrailingNewlinesAreStripped() throws {
        let request = try command(message: "-").makeNotificationRequest(readStandardInput: { "a\nb\n\n\n" })
        XCTAssertEqual(request.message, "a\nb")
    }

    func testInteriorNewlinesArePreserved() throws {
        let request = try command(message: "-").makeNotificationRequest(readStandardInput: { "a\n\nb\n" })
        XCTAssertEqual(request.message, "a\n\nb")
    }

    func testEmptyStandardInputProducesEmptyBody() throws {
        let request = try command(message: "-").makeNotificationRequest(readStandardInput: { "" })
        XCTAssertEqual(request.message, "")
    }

    func testOrdinaryMessageIsUsedVerbatimAndDoesNotReadStandardInput() throws {
        var readCount = 0
        let request = try command(message: "body").makeNotificationRequest(
            readStandardInput: {
                readCount += 1
                return "should not be used"
            })

        XCTAssertEqual(request.message, "body")
        XCTAssertEqual(readCount, 0)
    }

    /// 読み取りは通知リクエストの組み立て時に一度だけ行う。`validate()` は起動ゲートの
    /// 種別判定と中間の引き継ぎでも走るため、そこで読むと `--profile` 併用時に最終的な
    /// 本文が空になる (research.md F4)。
    func testStandardInputIsReadOnlyWhenBuildingTheRequest() throws {
        var readCount = 0
        var parsed = try command(message: "-")

        // 端末かどうかで throw の有無は変わる。ここで確かめたいのは、いずれの場合でも
        // `validate()` が標準入力を消費しないことだけ。
        try? parsed.validate()
        XCTAssertEqual(readCount, 0, "validate() が標準入力を消費している")

        _ = parsed.makeNotificationRequest(readStandardInput: {
            readCount += 1
            return "body"
        })
        XCTAssertEqual(readCount, 1)
    }

    // MARK: 標準入力が端末のとき (Requirement 5.3)

    func testRejectsHyphenMessageWhenStandardInputIsATerminal() throws {
        XCTAssertThrowsError(
            try NotifyCommand.validateMessageSource(message: "-", isStandardInputTerminal: true))
    }

    func testAcceptsHyphenMessageWhenStandardInputIsPiped() throws {
        XCTAssertNoThrow(
            try NotifyCommand.validateMessageSource(message: "-", isStandardInputTerminal: false))
    }

    func testOrdinaryMessageIsAcceptedEvenOnATerminal() throws {
        XCTAssertNoThrow(
            try NotifyCommand.validateMessageSource(message: "body", isStandardInputTerminal: true))
    }

    /// 端末のときは読み取りを開始しない (EOFを待ってハングしない)。
    func testTerminalRejectionMessageExplainsHowToPipeInput() throws {
        XCTAssertThrowsError(
            try NotifyCommand.validateMessageSource(message: "-", isStandardInputTerminal: true)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.lowercased().contains("standard input"), message)
        }
    }
}

// MARK: - 画像添付の事前検証 (Requirements 9.1〜9.5)

final class NotifyCommandImageValidationTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "yobirin-image-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    private func makeFile(named name: String) -> String {
        let path = "\(root!)/\(name)"
        FileManager.default.createFile(atPath: path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        return path
    }

    func testAcceptsSupportedImageExtensions() throws {
        for ext in ["png", "jpg", "jpeg", "gif", "PNG", "JPG"] {
            let path = makeFile(named: "icon.\(ext)")
            XCTAssertNoThrow(try NotifyCommand.validateImage(path: path), ext)
        }
    }

    func testAcceptsNoImage() throws {
        XCTAssertNoThrow(try NotifyCommand.validateImage(path: String?.none))
    }

    func testRejectsMissingPathAndNamesIt() throws {
        let missing = "\(root!)/does-not-exist.png"
        XCTAssertThrowsError(try NotifyCommand.validateImage(path: missing)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(missing), message)
        }
    }

    func testRejectsDirectory() throws {
        XCTAssertThrowsError(try NotifyCommand.validateImage(path: root))
    }

    func testRejectsUnsupportedExtensionAndListsSupportedOnes() throws {
        let path = makeFile(named: "clip.mp4")
        XCTAssertThrowsError(try NotifyCommand.validateImage(path: path)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("png"), message)
            XCTAssertTrue(message.contains("gif"), message)
        }
    }

    func testRejectsExtensionlessPath() throws {
        let path = makeFile(named: "icon")
        XCTAssertThrowsError(try NotifyCommand.validateImage(path: path))
    }

    /// フレームワーク由来の内部エラー表現をそのまま見せない (Requirement 9.4)。
    func testMessagesDoNotLeakFrameworkErrorRepresentation() throws {
        let path = makeFile(named: "clip.mp4")
        for target in ["\(root!)/nope.png", path] {
            XCTAssertThrowsError(try NotifyCommand.validateImage(path: target)) { error in
                let message = String(describing: error)
                XCTAssertFalse(message.contains("Error Domain="), message)
                XCTAssertFalse(message.contains("NSCocoaErrorDomain"), message)
            }
        }
    }

    /// 検証は通知許可を要求する前に完了する。`validate()` はパース時に走り、
    /// `run()` (認可の起点) より前に必ず実行される (Requirement 9.1)。
    func testValidationHappensAtParseTimeBeforeAnyAuthorization() throws {
        XCTAssertThrowsError(
            try NotifyCommand.parse(["-t", "t", "-m", "m", "--image", "\(root!)/nope.png"]))
    }

    func testValidImageParsesSuccessfully() throws {
        let path = makeFile(named: "icon.png")
        let command = try NotifyCommand.parse(["-t", "t", "-m", "m", "--image", path])
        XCTAssertEqual(command.image, path)
    }
}
