import ArgumentParser
import Darwin
import Foundation

/// `ps` サブコマンドの引数定義と待機プロセスの走査・一覧出力の結線 (design.md PsCommand、
/// Requirements 15.1〜15.8)。
///
/// 通知APIやAppKitの型に一切触れない (Requirement 15.9)。バンドル外の素のMach-Oからでも
/// 完走できる。ルートコマンドへの結線 (`YobirinCommand.subcommands` への追加・起動ゲートの
/// 許可リストへの追加) は本タスクの範囲外 (task 11.2)。
struct PsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List yobirin processes waiting for a notification result"
    )

    @Flag(help: "Print the list as machine-readable JSON to stdout")
    var json = false

    func run() {
        Self.perform(
            json: json,
            currentPID: getpid(),
            now: Date(),
            homeDirectory: NSHomeDirectory(),
            scan: Self.defaultScan,
            stdoutWriter: Self.defaultStdoutWriter,
            stderrWriter: Self.defaultStderrWriter,
            exit: { Darwin.exit($0) }
        )
    }

    /// 走査で得られる1プロセスの生データ。`argv` は読み取れなかった場合 `nil`
    /// (design.md PsCommand「argvが読み取れないプロセスは...欠損として表示し継続」、Requirement
    /// 15.7)。実行ファイルパス自体が読み取れないプロセスはそもそもレコードとして現れない
    /// (走査対象から自然に消える)。
    struct RawProcessRecord: Equatable {
        let pid: Int32
        let path: String
        let argv: [String]?
        let startTime: Date
    }

    /// 一覧の1項目 (design.md psJSON契約)。`profile` はデフォルトなら `nil`。`title` /
    /// `timeoutSeconds` はargvから読み取れなかった場合に `nil` (欠損)。
    struct Entry: Equatable {
        let pid: Int32
        let profile: String?
        let title: String?
        let timeoutSeconds: Int?
        let elapsedSeconds: Int
        let path: String
    }

    /// 走査 → 対象判定 → 表示値導出 → 整列 → テキスト/JSON整形の結線 (design.md PsCommand責務、
    /// Requirements 15.1〜15.8)。`scan` / `stdoutWriter` / `stderrWriter` / `exit` を注入して
    /// テストする (ListCommandと同じ方針)。
    static func perform(
        json: Bool,
        currentPID: Int32,
        now: Date,
        homeDirectory: String,
        scan: () throws -> [RawProcessRecord],
        stdoutWriter: (String) -> Void,
        stderrWriter: (String) -> Void,
        exit: (Int32) -> Void
    ) {
        let records: [RawProcessRecord]
        do {
            records = try scan()
        } catch {
            stderrWriter("Failed to scan processes: \(error)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        let entries = waitingEntries(
            from: records, currentPID: currentPID, now: now, homeDirectory: homeDirectory)

        stdoutWriter(json ? jsonString(for: entries) : textString(for: entries))
    }

    // MARK: - Target judgment and derivation (Requirements 15.2, 15.3, 15.4, 15.7)

    /// 対象判定 (自PID除外 → バンドル内パス判定 → argvの`--title`判定) を通過したレコードから
    /// 表示項目を導出し、起動時刻昇順 (同時刻はPID昇順) に整列する。
    private static func waitingEntries(
        from records: [RawProcessRecord], currentPID: Int32, now: Date, homeDirectory: String
    ) -> [Entry] {
        let candidates = records.compactMap {
            record -> (record: RawProcessRecord, profile: String?)? in
            guard record.pid != currentPID else { return nil }
            guard
                let recognized = recognizedBundle(forPath: record.path, homeDirectory: homeDirectory)
            else { return nil }

            switch record.argv {
            case nil:
                return (record, profileName(for: recognized))
            case .some(let argv):
                guard argvContainsTitleFlag(argv) else { return nil }
                return (record, profileName(for: recognized))
            }
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.record.startTime != rhs.record.startTime {
                return lhs.record.startTime < rhs.record.startTime
            }
            return lhs.record.pid < rhs.record.pid
        }

        return sorted.map { candidate in
            let argv = candidate.record.argv
            let elapsed = max(0, Int(now.timeIntervalSince(candidate.record.startTime)))
            return Entry(
                pid: candidate.record.pid,
                profile: candidate.profile,
                title: argv.flatMap { extractOption("--title", from: $0) },
                timeoutSeconds: argv.flatMap { extractOption("--timeout", from: $0) }.flatMap { Int($0) },
                elapsedSeconds: elapsed,
                path: candidate.record.path
            )
        }
    }

    /// 実行ファイルパスが命名規約のバンドル内Mach-Oかどうかを判定する (design.md「実行ファイル
    /// パスが `ProfileNaming.recognize` で逆引きできるバンドル内Mach-O」)。`.app` ディレクトリ名
    /// だけでなく、パス全体がその規約から導出される正確なMach-Oパスと一致することまで確認する
    /// (homeDirectory違いや配置階層のズレ・`Contents/MacOS/yobirin` 以外への棄却)。
    private static func recognizedBundle(forPath path: String, homeDirectory: String)
        -> ProfileNaming.RecognizedBundle?
    {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4 else { return nil }
        let appDirectoryName = String(components[components.count - 4])

        guard
            let recognized = ProfileNaming.recognize(
                appDirectoryName: appDirectoryName, homeDirectory: homeDirectory)
        else { return nil }

        let naming: ProfileNaming
        switch recognized {
        case .default:
            naming = .default(homeDirectory: homeDirectory)
        case .profile(let name):
            guard let forProfile = try? ProfileNaming.forProfile(name, homeDirectory: homeDirectory)
            else { return nil }
            naming = forProfile
        }
        guard naming.machOPath == path else { return nil }
        return recognized
    }

    private static func profileName(for recognized: ProfileNaming.RecognizedBundle) -> String? {
        switch recognized {
        case .default: return nil
        case .profile(let name): return name
        }
    }

    /// argvに `--title`/`--title=` が含まれるか (design.md「argvに`--title`/`--title=`を含む」)。
    /// notify系の必須オプションであり、`install`/`list`/`ps`/掃除 (引数なし) は持たない。
    private static func argvContainsTitleFlag(_ argv: [String]) -> Bool {
        argv.contains { $0 == "--title" || $0.hasPrefix("--title=") }
    }

    /// argvから `name` オプションの値を抽出する (`--title x` / `--title=x` 両形式、design.md
    /// 「タイムアウト指定 (`--title x` / `--title=x` 両形式の抽出)」)。
    private static func extractOption(_ name: String, from argv: [String]) -> String? {
        let prefix = name + "="
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg.hasPrefix(prefix) {
                return String(arg.dropFirst(prefix.count))
            }
            if arg == name {
                let valueIndex = index + 1
                guard valueIndex < argv.count else { return nil }
                return argv[valueIndex]
            }
            index += 1
        }
        return nil
    }

    // MARK: - Text formatting (0件は案内メッセージ、それ以外はヘッダ付き桁揃え表)

    private static func textString(for entries: [Entry]) -> String {
        guard !entries.isEmpty else {
            return "No processes are waiting for a notification result"
        }

        let header = (
            pid: "PID", profile: "PROFILE", title: "TITLE", timeout: "TIMEOUT", elapsed: "ELAPSED"
        )
        let rows = entries.map { entry in
            (
                pid: String(entry.pid),
                profile: entry.profile ?? "(default)",
                title: entry.title ?? "-",
                timeout: entry.timeoutSeconds.map(String.init) ?? "-",
                elapsed: formatElapsed(entry.elapsedSeconds)
            )
        }

        let pidWidth = ([header.pid] + rows.map(\.pid)).map(\.count).max() ?? 0
        let profileWidth = ([header.profile] + rows.map(\.profile)).map(\.count).max() ?? 0
        let titleWidth = ([header.title] + rows.map(\.title)).map(\.count).max() ?? 0
        let timeoutWidth = ([header.timeout] + rows.map(\.timeout)).map(\.count).max() ?? 0

        func formatRow(
            _ row: (pid: String, profile: String, title: String, timeout: String, elapsed: String)
        ) -> String {
            let pid = row.pid.padding(toLength: pidWidth, withPad: " ", startingAt: 0)
            let profile = row.profile.padding(toLength: profileWidth, withPad: " ", startingAt: 0)
            let title = row.title.padding(toLength: titleWidth, withPad: " ", startingAt: 0)
            let timeout = row.timeout.padding(toLength: timeoutWidth, withPad: " ", startingAt: 0)
            return "\(pid)  \(profile)  \(title)  \(timeout)  \(row.elapsed)"
        }

        var lines = [formatRow(header)]
        lines.append(contentsOf: rows.map(formatRow))
        return lines.joined(separator: "\n")
    }

    /// 経過秒数を人間可読に整形する (`42s` / `12m34s` / `1h02m` 風、design.md psJSON契約
    /// 「テキスト表示の経過時間は人間可読に整形する」)。JSON側は `elapsedSeconds` を秒数のまま出す。
    private static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return String(format: "%dm%02ds", minutes, remainingSeconds)
        }
        let hours = seconds / 3600
        let remainingMinutes = (seconds % 3600) / 60
        return String(format: "%dh%02dm", hours, remainingMinutes)
    }

    // MARK: - JSON formatting (design.md psJSON契約)

    private static func jsonString(for entries: [Entry]) -> String {
        let items = entries.map { entry -> String in
            let pairs: [(String, String)] = [
                ("pid", String(entry.pid)),
                ("profile", jsonValue(entry.profile)),
                ("title", jsonValue(entry.title)),
                ("timeoutSeconds", entry.timeoutSeconds.map(String.init) ?? "null"),
                ("elapsedSeconds", String(entry.elapsedSeconds)),
                ("path", jsonStringLiteral(entry.path)),
            ]
            let body = pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
            return "{\(body)}"
        }
        return "{\"processes\":[\(items.joined(separator: ","))]}"
    }

    private static func jsonValue(_ value: String?) -> String {
        guard let value else { return "null" }
        return jsonStringLiteral(value)
    }

    /// 文字列をJSON文字列リテラルへエンコードする (エスケープ・UTF-8はJSONEncoderへ委譲。
    /// `ListCommand.jsonStringLiteral` と同じ方針)。
    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let json = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return json
    }

    // MARK: - Default injections (Darwin syscalls, design.md「走査は`proc_listpids`で...」)

    /// 自ユーザーの全プロセスを列挙し、各PIDの実行パス・argv・起動時刻を読む。他ユーザーの
    /// プロセスはargv/起動時刻の読み取りが `errno=EINVAL` で失敗するため走査対象から自然に除外
    /// される (research.md 2026-07-28スパイク実測)。
    private static func defaultScan() throws -> [RawProcessRecord] {
        let pids = try listAllPIDs()
        return pids.compactMap { pid -> RawProcessRecord? in
            guard let path = executablePath(for: pid) else { return nil }
            guard let startTime = startTime(for: pid) else { return nil }
            return RawProcessRecord(pid: pid, path: path, argv: readArgv(for: pid), startTime: startTime)
        }
    }

    private struct ScanError: Error {}

    /// `proc_listpids` でシステム上の全PIDを列挙する (Requirement 15.8: 列挙自体の失敗は環境
    /// エラー)。先頭の呼び出しで必要バイト数を問い合わせ、余裕を持たせたバッファで本取得する。
    private static func listAllPIDs() throws -> [Int32] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { throw ScanError() }

        let capacity = Int(requiredBytes) / MemoryLayout<Int32>.size + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let filledBytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<Int32>.size))
        guard filledBytes > 0 else { throw ScanError() }

        let count = min(capacity, Int(filledBytes) / MemoryLayout<Int32>.size)
        return pids[0..<count].filter { $0 > 0 }
    }

    private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `kinfo_proc.p_starttime` からプロセスの起動時刻を読む (design.md「起動時刻:
    /// sysctl [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]」)。
    private static func startTime(for pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }

        let seconds = TimeInterval(info.kp_proc.p_starttime.tv_sec)
        let microseconds = TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: seconds + microseconds)
    }

    /// `KERN_PROCARGS2` からargvを読む (design.md「先頭Int32=argc → exec_path (NUL終端) →
    /// NULパディングスキップ → argv文字列群」)。他ユーザーは `errno=EINVAL` で失敗し `nil` を返す。
    private static func readArgv(for pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 4 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= 4 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var offset = 4
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }

        var argv: [String] = []
        var current: [UInt8] = []
        var remaining = argc
        while offset < buffer.count, remaining > 0 {
            let byte = buffer[offset]
            if byte == 0 {
                argv.append(String(decoding: current, as: UTF8.self))
                current = []
                remaining -= 1
            } else {
                current.append(byte)
            }
            offset += 1
        }
        return argv
    }

    private static func defaultStdoutWriter(_ text: String) {
        print(text)
    }

    private static func defaultStderrWriter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
