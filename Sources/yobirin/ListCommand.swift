import ArgumentParser
import Darwin
import Foundation

/// `list` サブコマンドの引数定義とバンドル走査・一覧出力の結線 (design.md ListCommand、
/// Requirements 14.1〜14.9)。
///
/// 通知APIやAppKitの型に一切触れない (Requirement 14.10)。バンドル外の素のMach-Oからでも
/// 完走できる。ルートコマンドへの結線 (`YobirinCommand.subcommands` への追加・起動ゲートの
/// 許可リストへの追加) は本タスクの範囲外。
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed bundles (default and profiles)"
    )

    @Flag(help: "Print the list as machine-readable JSON to stdout")
    var json = false

    func run() {
        Self.perform(
            json: json,
            homeDirectory: NSHomeDirectory(),
            fileManager: .default,
            listDirectory: Self.defaultListDirectory,
            stdoutWriter: Self.defaultStdoutWriter,
            stderrWriter: Self.defaultStderrWriter,
            exit: { Darwin.exit($0) }
        )
    }

    /// 配置済みバンドルの1項目 (design.md 一覧JSON契約)。`profile` はデフォルトなら `nil`。
    /// `bundleID` / `version` は配置済みInfo.plistから読めなかった場合に `nil` (欠損)。
    struct Entry: Equatable {
        let profile: String?
        let bundleID: String?
        let version: String?
        let path: String
    }

    /// 走査 → 対象判定 → 実態読み取り → 整列 → テキスト/JSON整形の結線
    /// (design.md ListCommand責務、Requirements 14.1〜14.9)。`listDirectory` / `fileManager` /
    /// `stdoutWriter` / `stderrWriter` / `exit` を注入してテストする (Installerと同じ方針)。
    static func perform(
        json: Bool,
        homeDirectory: String,
        fileManager: FileManager,
        listDirectory: (String) throws -> [String],
        stdoutWriter: (String) -> Void,
        stderrWriter: (String) -> Void,
        exit: (Int32) -> Void
    ) {
        let entries: [Entry]
        do {
            entries = try scan(
                homeDirectory: homeDirectory, fileManager: fileManager, listDirectory: listDirectory)
        } catch {
            stderrWriter("Failed to scan the install directory: \(error)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        stdoutWriter(json ? jsonString(for: entries) : textString(for: entries))
    }

    /// `~/Applications` を走査し、`ProfileNaming.recognize` で規約に一致するバンドルだけを対象へ
    /// 残す (14.7)。ディレクトリ自体が存在しないときは空配列 (14.6)。存在するが列挙に失敗したときは
    /// `listDirectory` が投げたエラーをそのまま呼び出し元へ伝える (14.9)。
    private static func scan(
        homeDirectory: String,
        fileManager: FileManager,
        listDirectory: (String) throws -> [String]
    ) throws -> [Entry] {
        let applicationsDirectory = "\(homeDirectory)/Applications"
        guard fileManager.fileExists(atPath: applicationsDirectory) else {
            return []
        }

        let itemNames = try listDirectory(applicationsDirectory)
        var entries: [Entry] = []
        for itemName in itemNames {
            let itemPath = "\(applicationsDirectory)/\(itemName)"
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                continue
            }
            guard
                let recognized = ProfileNaming.recognize(
                    appDirectoryName: itemName, homeDirectory: homeDirectory)
            else {
                continue
            }

            let profile: String?
            switch recognized {
            case .default: profile = nil
            case .profile(let name): profile = name
            }

            let (bundleID, version) = readBundleInfo(bundlePath: itemPath, fileManager: fileManager)
            entries.append(Entry(profile: profile, bundleID: bundleID, version: version, path: itemPath))
        }

        return entries.sorted { lhs, rhs in
            switch (lhs.profile, rhs.profile) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let l?, let r?): return l < r
            }
        }
    }

    /// 配置済み `Contents/Info.plist` から `CFBundleIdentifier` / `CFBundleShortVersionString` を
    /// 読む (規約からの導出値ではなく実態を表示するため)。読めないキー・plist自体は個別に `nil`
    /// (欠損) とし、他の項目の一覧表示を止めない (14.8)。
    private static func readBundleInfo(bundlePath: String, fileManager: FileManager) -> (
        bundleID: String?, version: String?
    ) {
        let plistPath = "\(bundlePath)/Contents/Info.plist"
        guard let data = fileManager.contents(atPath: plistPath),
            let plistObject = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let plist = plistObject as? [String: Any]
        else {
            return (nil, nil)
        }
        return (
            plist["CFBundleIdentifier"] as? String, plist["CFBundleShortVersionString"] as? String
        )
    }

    // MARK: - Text formatting (0件は案内メッセージ、それ以外はヘッダ付き桁揃え表)

    private static func textString(for entries: [Entry]) -> String {
        guard !entries.isEmpty else {
            return "No installed bundles (run 'yobirin install' to install)"
        }

        let header = (profile: "PROFILE", bundleID: "BUNDLE ID", version: "VERSION", path: "PATH")
        let rows = entries.map { entry in
            (
                profile: entry.profile ?? "(default)",
                bundleID: entry.bundleID ?? "-",
                version: entry.version ?? "-",
                path: entry.path
            )
        }

        let profileWidth = ([header.profile] + rows.map(\.profile)).map(\.count).max() ?? 0
        let bundleIDWidth = ([header.bundleID] + rows.map(\.bundleID)).map(\.count).max() ?? 0
        let versionWidth = ([header.version] + rows.map(\.version)).map(\.count).max() ?? 0

        func formatRow(_ row: (profile: String, bundleID: String, version: String, path: String))
            -> String
        {
            let profile = row.profile.padding(toLength: profileWidth, withPad: " ", startingAt: 0)
            let bundleID = row.bundleID.padding(toLength: bundleIDWidth, withPad: " ", startingAt: 0)
            let version = row.version.padding(toLength: versionWidth, withPad: " ", startingAt: 0)
            return "\(profile)  \(bundleID)  \(version)  \(row.path)"
        }

        var lines = [formatRow(header)]
        lines.append(contentsOf: rows.map(formatRow))
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON formatting (design.md 一覧JSON契約)

    private static func jsonString(for entries: [Entry]) -> String {
        let items = entries.map { entry -> String in
            let pairs: [(String, String)] = [
                ("profile", jsonValue(entry.profile)),
                ("bundleID", jsonValue(entry.bundleID)),
                ("version", jsonValue(entry.version)),
                ("path", jsonStringLiteral(entry.path)),
            ]
            let body = pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
            return "{\(body)}"
        }
        return "{\"bundles\":[\(items.joined(separator: ","))]}"
    }

    private static func jsonValue(_ value: String?) -> String {
        guard let value else { return "null" }
        return jsonStringLiteral(value)
    }

    /// 文字列をJSON文字列リテラルへエンコードする (エスケープ・UTF-8はJSONEncoderへ委譲。
    /// `ResultOutput.jsonString` と同じ方針)。
    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let json = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return json
    }

    // MARK: - Default injections

    private static func defaultListDirectory(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    private static func defaultStdoutWriter(_ text: String) {
        print(text)
    }

    private static func defaultStderrWriter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
