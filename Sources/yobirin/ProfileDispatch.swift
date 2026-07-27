import Darwin
import Foundation

/// プロファイル名からバンドル名・Bundle ID・配置パスを導出する規約の単一ソース
/// (design.md Install layout > アイコンのプロファイル方式、Requirements 10.1, 10.4, 10.5)。
///
/// 旧シェル実装 (scripts/install.sh / scripts/build-app.sh) の命名規約を踏襲する:
/// appName `Yobirin` / `Yobirin-<先頭大文字化した名前>`、bundleID `com.mjun0812.yobirin` /
/// `com.mjun0812.yobirin.<name>`、配置 `~/Applications/<appName>.app`。
/// task 7.3 のインストーラも本型を経由してこの規約を参照する前提の公開API。
struct ProfileNaming: Equatable {
    static let executableName = "yobirin"
    static let defaultBundleID = "com.mjun0812.yobirin"

    let appName: String
    let bundleID: String
    let bundlePath: String
    let machOPath: String

    enum ValidationError: Error, Equatable {
        case invalidName(String)
    }

    /// プロファイル名の検証。`^[a-z0-9]+$` (英小文字・数字のみ、1文字以上)。
    /// パス注入防止のための制約であり、旧シェル実装の検証をそのまま踏襲する。
    static func validate(_ name: String) throws {
        let isValid =
            !name.isEmpty
            && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard isValid else {
            throw ValidationError.invalidName(name)
        }
    }

    /// デフォルト (プロファイル指定なし) の導出。
    static func `default`(homeDirectory: String = NSHomeDirectory()) -> ProfileNaming {
        make(appName: "Yobirin", bundleID: defaultBundleID, homeDirectory: homeDirectory)
    }

    /// 指定プロファイルの導出。`name` は `^[a-z0-9]+$` を満たさなければならない。
    static func forProfile(_ name: String, homeDirectory: String = NSHomeDirectory()) throws
        -> ProfileNaming
    {
        try validate(name)
        let capitalized = name.prefix(1).uppercased() + name.dropFirst()
        return make(
            appName: "Yobirin-\(capitalized)",
            bundleID: "\(defaultBundleID).\(name)",
            homeDirectory: homeDirectory
        )
    }

    /// `profile` が nil ならデフォルト、非nilなら指定プロファイルを導出する
    /// (task 7.3のインストーラが共通して使う想定の窓口)。
    static func resolve(profile: String?, homeDirectory: String = NSHomeDirectory()) throws
        -> ProfileNaming
    {
        guard let profile else {
            return .default(homeDirectory: homeDirectory)
        }
        return try forProfile(profile, homeDirectory: homeDirectory)
    }

    private static func make(appName: String, bundleID: String, homeDirectory: String)
        -> ProfileNaming
    {
        let bundlePath = "\(homeDirectory)/Applications/\(appName).app"
        return ProfileNaming(
            appName: appName,
            bundleID: bundleID,
            bundlePath: bundlePath,
            machOPath: "\(bundlePath)/Contents/MacOS/\(executableName)"
        )
    }

    /// バンドルディレクトリ名の逆引き結果 (design.md ListCommand「往復一致」、Requirement 14.7)。
    enum RecognizedBundle: Equatable {
        case `default`
        case profile(String)
    }

    /// バンドルディレクトリ名 (`Yobirin.app` / `Yobirin-<Suffix>.app`) からプロファイルを逆引きする
    /// (design.md ListCommand責務、Requirement 14.7)。
    ///
    /// 往復一致 (逆引きした名前から順方向導出したappNameが同じディレクトリ名になる) を要求する。
    /// `Yobirin-ABC.app` (順方向導出は `Yobirin-Abc`) や `Yobirin-My-App.app` (`my-app` は
    /// `validate` を通らない) のような規約外の名前は `nil` を返して棄却する。
    static func recognize(appDirectoryName: String, homeDirectory: String = NSHomeDirectory())
        -> RecognizedBundle?
    {
        let suffix = ".app"
        guard appDirectoryName.hasSuffix(suffix) else { return nil }
        let appName = String(appDirectoryName.dropLast(suffix.count))

        if appName == "Yobirin" {
            return .default
        }

        let profilePrefix = "Yobirin-"
        guard appName.hasPrefix(profilePrefix) else { return nil }
        let candidate = appName.dropFirst(profilePrefix.count).lowercased()

        guard let naming = try? forProfile(candidate, homeDirectory: homeDirectory),
            naming.appName == appName
        else {
            return nil
        }
        return .profile(candidate)
    }
}

/// `--profile` 指定時に対象バンドルのMach-Oへ実行を引き継ぐ薄いディスパッチ
/// (design.md フローに関する決定、Requirements 10.4, 10.5)。
///
/// exec先は同じyobirinバイナリのバンドル内実行になるため、引数から `--profile` を除いて
/// 透過する。ディスパッチ先には `--profile` が渡らないため、再ディスパッチは構造的に起きない。
enum ProfileDispatch {
    /// execの実行を差し替え可能にする関数型。既定実装 (`defaultExec`) は `Darwin.execv` を呼ぶ。
    /// execvは成功するとプロセスイメージを置き換えるため返らない。返ってきた場合は失敗を意味する。
    typealias Exec = (_ path: String, _ arguments: [String]) -> Void

    /// `arguments` (`CommandLine.arguments` 相当。先頭はargv[0]) から `--profile <value>` /
    /// `--profile=<value>` を除去し、argv[0]を `machOPath` に差し替えた引数列を構築する
    /// (純粋関数。design.md「引数から--profileを除いて透過する」)。
    static func buildExecArguments(machOPath: String, arguments: [String]) -> [String] {
        var result = [machOPath]
        var rest = arguments.dropFirst()
        while !rest.isEmpty {
            let arg = rest.removeFirst()
            if arg == "--profile" {
                if !rest.isEmpty { rest.removeFirst() }  // 値を読み捨てる
                continue
            }
            if arg.hasPrefix("--profile=") {
                continue
            }
            result.append(arg)
        }
        return result
    }

    /// `profile` バンドルのMach-Oへディスパッチする。プロファイル名が不正、または対象バンドルが
    /// 未インストールのときはJSONを出力せず、理由をstderrへ出して非0終了する
    /// (Requirement 10.5。design.md Error Handling「環境エラー」の規約に従う)。execvが返ってきた
    /// 場合 (失敗) も同様に扱う。
    static func dispatch(
        profile: String,
        arguments: [String] = CommandLine.arguments,
        homeDirectory: String = NSHomeDirectory(),
        isInstalled: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        stderrWriter: (String) -> Void = Self.defaultStderrWriter,
        exit: (Int32) -> Void = { Darwin.exit($0) },
        exec: Exec = Self.defaultExec
    ) {
        guard let naming = try? ProfileNaming.forProfile(profile, homeDirectory: homeDirectory)
        else {
            stderrWriter("不正なプロファイル名です: \"\(profile)\" (使用できるのは英小文字と数字のみ)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        guard isInstalled(naming.machOPath) else {
            stderrWriter("プロファイル \"\(profile)\" はインストールされていません: \(naming.bundlePath)")
            exit(ResultEmitter.environmentErrorExitCode)
            return
        }

        exec(naming.machOPath, buildExecArguments(machOPath: naming.machOPath, arguments: arguments))

        // execvはプロセス置換に成功すると返らない。ここに到達するのは失敗時のみ。
        stderrWriter("プロファイル \"\(profile)\" の起動に失敗しました: \(String(cString: strerror(errno)))")
        exit(ResultEmitter.environmentErrorExitCode)
    }

    private static func defaultStderrWriter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// `BundleEnvironment.reExecThroughSymlinkIfNeeded` からも共用するためinternal。
    static func defaultExec(_ path: String, _ arguments: [String]) {
        var cArgs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArgs.append(nil)
        execv(path, &cArgs)
    }
}
