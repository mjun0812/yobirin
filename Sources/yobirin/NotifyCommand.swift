import AppKit
import ArgumentParser
import Darwin
import Foundation

/// 通知送信の既定サブコマンド (design.md CLI契約、Requirements 1, 2, 4, 5)。
/// ルートコマンド (`YobirinCommand`) の `defaultSubcommand` に指定され、従来の
/// `yobirin --title <str> --message <str> ...` 形式はそのままこのサブコマンドへ解決される
/// (Requirement 11.8)。
/// - Important: 短縮形に `allowingJoined: true` を指定してはならない。結合表記 (`-pclaude`)
///   を受理すると `ProfileDispatch.buildExecArguments` のプロファイル指定の除去が不完全になり、
///   引き継ぎ先で再ディスパッチが起きて exec が無限ループする (research.md F2, R-2)。
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Deliver a notification and print the captured response as JSON",
        discussion: """
            Examples:

              Announce a finished build and give up after five minutes:
                yobirin -t "Build finished" -m "All tests passed" --timeout 5m

              Ask for approval with action buttons and branch on the exit code:
                yobirin -t Deploy -m "Release to production?" \\
                  -a Approve -a Reject --exit-code --timeout 10m
                # exit 10 = Approve, 11 = Reject, 3 = dismissed, 4 = timed out

              Capture a text reply without parsing JSON:
                answer=$(yobirin -t "Claude Code" -m "Next instruction?" \\
                  --reply --print text --timeout 5m)
            """
    )

    @Option(name: [.short, .long], help: "The notification title")
    var title: String

    @Option(name: [.short, .long], help: "The notification body")
    var message: String

    @Option(name: [.short, .long], help: "Deliver via the bundle of the specified profile")
    var profile: String?

    @Option(help: "The notification subtitle")
    var subtitle: String?

    @Option(help: "Group ID; replaces an existing notification with the same group")
    var group: String?

    @Option(
        help: """
            How long to wait for a response (waits forever when omitted). \
            A bare number is seconds; units h/m/s may be combined, e.g. 90s, 5m, 1h30m
            """,
        transform: Self.parseTimeout)
    var timeout: Double?

    @Option(name: [.short, .long], help: "Action button label (repeatable)")
    var action: [String] = []

    @Flag(help: "Enable the text reply field")
    var reply = false

    @Option(help: "Placeholder text for the reply field (requires --reply)")
    var replyPlaceholder: String?

    @Option(help: "Notification sound ('default' or a sound name)")
    var sound: String?

    @Option(help: "Path of an image to attach (png, jpg, jpeg, or gif)")
    var image: String?

    @Flag(
        name: .customLong("exit-code"),
        help: "Map the result to the exit code: clicked/replied 0, dismissed 3, timeout 4, action 10+index")
    var exitCodeEnabled = false

    @Option(
        help: "Print only this field of the result instead of the JSON (result, action, actionIndex, or text)")
    var print: PrintField?

    /// 入力の検証 (Requirements 5.3, 9.1)。
    ///
    /// - Important: ここに副作用を置いてはならない。`validate()` は起動ゲートの種別判定
    ///   (`parseAsRoot` がパースの一環で実行する) と、プロファイルへの引き継ぎ元のホップでも
    ///   走るため、最終的に通知を配信するプロセスまでに複数回実行される。標準入力の読み取りを
    ///   ここへ置くと、引き継ぎ前に消費されて引き継ぎ先の本文が空になる (research.md F4)。
    ///   読み取りは `makeNotificationRequest()` で行う。
    mutating func validate() throws {
        if replyPlaceholder != nil, !reply {
            throw ValidationError("--reply-placeholder requires --reply")
        }
        try Self.validateMessageSource(
            message: message,
            isStandardInputTerminal: TerminalDetection.defaultPredicate(STDIN_FILENO)
        )
        try Self.validateImage(path: image)
    }

    /// 添付として対応する画像形式 (research.md R-1: Apple Developer Documentation)。
    /// `--image` というオプション名と既定のヘルプが画像を前提としているため、音声・動画は
    /// 受け付けない。
    static let supportedImageExtensions = ["png", "jpg", "jpeg", "gif"]

    /// 画像添付の事前検証 (Requirements 9.1〜9.5)。
    ///
    /// 通知許可を要求する前に失敗させる。検証しないと、許可のダイアログを経たうえで
    /// 添付生成の失敗としてフレームワーク由来の生のエラー表現が露出する。
    /// ファイルI/Oのみで副作用がないため、`validate()` の複数回実行に対して安全
    /// (`validate()` のコメントを参照)。
    static func validateImage(path: String?) throws {
        guard let path else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ValidationError("--image file not found: \(path)")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ValidationError("--image file is not readable: \(path)")
        }

        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard supportedImageExtensions.contains(fileExtension) else {
            throw ValidationError(
                "--image must be one of: \(supportedImageExtensions.joined(separator: ", ")) "
                    + "(got: \(path))")
        }
    }

    /// 本文を標準入力から読む指定 (`-`) の妥当性 (Requirement 5.3)。
    ///
    /// 標準入力が端末に接続されている場合は読み取りを開始しない。開始するとEOFが来るまで
    /// ハングし、利用者からは固まったように見える。判定のみで、読み取りは伴わない。
    static func validateMessageSource(message: String, isStandardInputTerminal: Bool) throws {
        guard message == standardInputMarker, isStandardInputTerminal else { return }
        throw ValidationError(
            "--message - reads the body from standard input, but standard input is a terminal. "
                + "Pipe data in, for example: tail -3 build.log | yobirin -t Build -m -")
    }

    /// タイムアウト指定の解釈 (Requirements 4.1〜4.5)。変換規則は `TimeoutDuration` に集約し、
    /// `PsCommand` のargv解釈と同一の定義を共有する (Requirement 14.4)。
    private static func parseTimeout(_ value: String) throws -> Double {
        guard let seconds = TimeoutDuration.seconds(from: value) else {
            throw ValidationError(
                "--timeout must be a positive duration: a bare number of seconds (300, 0.5) "
                    + "or units h/m/s, optionally combined (90s, 5m, 1h30m)")
        }
        return seconds
    }

    /// 出力方針の構築 (Requirements 1, 2, 3)。
    ///
    /// `--exit-code` と `--print` の同時指定は検証エラーにしない (Requirement 3.2) —
    /// stdoutは生値・終了コードは結果依存、という組み合わせがそのまま成立する。
    /// 未指定なら `.default` で、従来の「JSON全体 + exit 0」を保つ。
    func makeOutputPolicy() -> OutputPolicy {
        OutputPolicy(exitCodeEnabled: exitCodeEnabled, printField: print)
    }

    /// 本文の値がこの文字列のとき、標準入力から本文を読む (Requirement 5.1)。
    static let standardInputMarker = "-"

    /// パース済みオプションから通知リクエストを組み立てる。
    ///
    /// 標準入力の読み取りはここで行う。この関数はプロファイルへの引き継ぎが済んだ最終ホップ
    /// でしか実行されないため、読み取った内容が確実に配信へ使われる (Requirement 5.5)。
    func makeNotificationRequest(
        readStandardInput: () -> String = Self.defaultReadStandardInput
    ) -> NotificationRequest {
        NotificationRequest(
            title: title,
            message: resolvedMessage(readStandardInput: readStandardInput),
            subtitle: subtitle,
            group: group,
            timeout: timeout,
            actions: action,
            replyEnabled: reply,
            replyPlaceholder: replyPlaceholder,
            sound: sound,
            image: image
        )
    }

    /// 本文の解決。`-` のときだけ標準入力を読み、末尾の改行を取り除く (Requirements 5.1, 5.2)。
    /// 読み取った内容の途中の改行はそのまま残す。
    private func resolvedMessage(readStandardInput: () -> String) -> String {
        guard message == Self.standardInputMarker else { return message }
        var body = readStandardInput()
        while body.hasSuffix("\n") {
            body.removeLast()
        }
        return body
    }

    private static func defaultReadStandardInput() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// 引数パース → 認可 → group置換 → category登録 → 配信 → 応答/タイマー → JSON出力 → 遅延exit
    /// の一連のフローを結線する (design.md System Flows、Requirements 3.6, 8.3)。
    ///
    /// `--profile` 指定時は、NSApplication・UN型に触れる前に対象バンドルのMach-Oへ
    /// ディスパッチする (design.md フローに関する決定、Requirements 10.4, 10.5)。
    func run() throws {
        if let profile {
            ProfileDispatch.dispatch(profile: profile)
            return
        }

        let request = makeNotificationRequest()
        let client = UNNotificationCenterAdapter()
        let delegate = AppDelegate(
            request: request,
            client: client,
            outputPolicy: makeOutputPolicy(),
            onOutput: { output in
                ExitCoordinator.finish(
                    output,
                    writer: ExitCoordinator.defaultWriter,
                    scheduler: DispatchQueueScheduler.schedule,
                    exit: { Darwin.exit($0) }
                )
            }
        )
        // 通知系経路の冒頭 (認可要求より前) で登録する (design.md CancellationSignal、
        // Requirements 2.5, 2.6)。`application.run()` は返らないため、このスタックフレーム上の
        // `withExtendedLifetime` による保持がプロセス生存中の受信を保証する
        // (design.md CancellationSignal Postconditions)。
        let cancellationSource = CancellationSignal.install { delegate.handleCancel() }

        let application = NSApplication.shared
        application.delegate = delegate
        withExtendedLifetime(cancellationSource) {
            application.run()
        }
    }
}
