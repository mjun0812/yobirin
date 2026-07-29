import XCTest

@testable import yobirin

/// 起動ゲートの分岐判定 (design.md 起動ゲートのフロー、Requirements 11.3, 11.6, 12.1, 12.2, 15.5)。
///
/// `LaunchGate.decide` は「引数の有無 → 端末接続 → バンドル内外 → コマンド種別」で分岐を決める
/// 純粋関数。種別の判定 (引数 → `CommandKind`) は `classify` の責務であり、ここでは種別を
/// 直接与えて分岐だけを検証する。
final class LaunchGateTests: XCTestCase {
    private func decide(
        _ kind: CommandKind,
        arguments: [String] = ["/path/to/yobirin", "--title", "t", "--message", "m"],
        isOutsideBundle: Bool,
        isDefaultBundleInstalled: Bool = false,
        isInteractive: Bool = false
    ) -> LaunchGate.Decision {
        LaunchGate.decide(
            arguments: arguments,
            kind: kind,
            isOutsideBundle: isOutsideBundle,
            isDefaultBundleInstalled: isDefaultBundleInstalled,
            isInteractive: isInteractive
        )
    }

    private let argumentless = ["/path/to/yobirin"]

    // MARK: - 引数なし起動 (Requirements 12.1, 12.2)

    /// 端末から `yobirin` とだけ打った利用者には、無言で終わるのではなくヘルプを見せる。
    func testArgumentlessAndInteractiveShowsHelp() {
        XCTAssertEqual(
            decide(.bundleFree, arguments: argumentless, isOutsideBundle: false, isInteractive: true),
            .showHelp)
        XCTAssertEqual(
            decide(.bundleFree, arguments: argumentless, isOutsideBundle: true, isInteractive: true),
            .showHelp)
    }

    /// 非対話の引数なし起動はLaunchServices経由の再起動とみなし、従来どおり孤児通知を掃除する。
    func testArgumentlessAndNonInteractiveInsideBundleSweepsOrphans() {
        XCTAssertEqual(
            decide(.bundleFree, arguments: argumentless, isOutsideBundle: false), .sweepOrphans)
    }

    func testArgumentlessAndNonInteractiveOutsideBundleExecsInstalledBundle() {
        XCTAssertEqual(
            decide(
                .bundleFree, arguments: argumentless, isOutsideBundle: true,
                isDefaultBundleInstalled: true),
            .execInstalledBundle)
    }

    func testArgumentlessAndNonInteractiveOutsideBundleWithoutInstallGuidesInstall() {
        XCTAssertEqual(
            decide(.bundleFree, arguments: argumentless, isOutsideBundle: true), .guideInstall)
    }

    func testEmptyArgumentListIsTreatedAsArgumentless() {
        XCTAssertEqual(decide(.bundleFree, arguments: [], isOutsideBundle: false), .sweepOrphans)
    }

    // MARK: - バンドル内は常にArgumentParserへ委ねる

    func testInsideBundleRunsCLIForEveryKind() {
        for kind in [CommandKind.requiresBundle, .diagnostic, .bundleFree] {
            XCTAssertEqual(decide(kind, isOutsideBundle: false), .runCLI, "\(kind)")
        }
    }

    /// 対話かどうかは引数ありの経路の分岐に影響しない。
    func testInteractivityDoesNotAffectNonArgumentlessLaunches() {
        XCTAssertEqual(decide(.bundleFree, isOutsideBundle: false, isInteractive: true), .runCLI)
    }

    // MARK: - バンドル外 × 通知APIに依存しない種別 (Requirements 11.6, 8.4)

    func testOutsideBundleWithBundleFreeRunsCLIRegardlessOfInstallState() {
        XCTAssertEqual(decide(.bundleFree, isOutsideBundle: true), .runCLI)
        XCTAssertEqual(
            decide(.bundleFree, isOutsideBundle: true, isDefaultBundleInstalled: true), .runCLI)
    }

    /// 通知APIに依存しない種別に対して引き継ぎや案内を返さないことを不変条件とする。
    func testBundleFreeNeverHandsOffOrGuides() {
        for installed in [true, false] {
            for interactive in [true, false] {
                let decision = decide(
                    .bundleFree, isOutsideBundle: true, isDefaultBundleInstalled: installed,
                    isInteractive: interactive)
                XCTAssertNotEqual(decision, .execInstalledBundle)
                XCTAssertNotEqual(decision, .guideInstall)
            }
        }
    }

    // MARK: - バンドル外 × バンドルを必要とする種別 (Requirement 11.3)

    func testOutsideBundleWithRequiresBundleExecsInstalledBundle() {
        XCTAssertEqual(
            decide(.requiresBundle, isOutsideBundle: true, isDefaultBundleInstalled: true),
            .execInstalledBundle)
    }

    func testOutsideBundleWithRequiresBundleGuidesInstallWhenNotInstalled() {
        XCTAssertEqual(decide(.requiresBundle, isOutsideBundle: true), .guideInstall)
    }

    func testOmittingBundleInstalledParameterDefaultsToNotInstalled() {
        XCTAssertEqual(
            LaunchGate.decide(
                arguments: ["/path/to/yobirin", "--title", "t", "--message", "m"],
                kind: .requiresBundle, isOutsideBundle: true),
            .guideInstall)
    }

    // MARK: - バンドル外 × 診断 (Requirement 15.5)

    func testOutsideBundleWithDiagnosticExecsInstalledBundleWhenInstalled() {
        XCTAssertEqual(
            decide(.diagnostic, isOutsideBundle: true, isDefaultBundleInstalled: true),
            .execInstalledBundle)
    }

    /// 診断だけは未インストールでも案内で終わらせない。インストール状態そのものが診断対象のため。
    func testOutsideBundleWithDiagnosticRunsCLIWhenNotInstalled() {
        XCTAssertEqual(decide(.diagnostic, isOutsideBundle: true), .runCLI)
    }
}

// MARK: - コマンド種別の判定 (Requirements 11.1, 11.2, 11.5, 8.4, 8.6)

/// 種別判定は引数文字列の位置走査ではなく、ルートコマンドの解決結果の型で行う。
/// 既定の解決処理 (`YobirinCommand.parseAsRoot`) を使い、実際の文法どおりに分類されることを
/// 確認する。解決処理は注入可能で、失敗ケースの分類も検証する。
final class LaunchGateClassifyTests: XCTestCase {
    /// 既存の `decide` と同じく、引数列は実行ファイル名を含む `CommandLine.arguments` 相当。
    private func classify(_ arguments: [String]) -> CommandKind {
        LaunchGate.classify(arguments: ["/path/to/yobirin"] + arguments)
    }

    // MARK: バンドルを必要とする種別

    func testNotifyArgumentsRequireBundle() {
        XCTAssertEqual(classify(["--title", "t", "--message", "m"]), .requiresBundle)
    }

    func testExplicitNotifySubcommandRequiresBundle() {
        XCTAssertEqual(classify(["notify", "--title", "t", "--message", "m"]), .requiresBundle)
    }

    func testSweepRequiresBundle() {
        XCTAssertEqual(classify(["sweep"]), .requiresBundle)
    }

    // MARK: 診断

    func testDoctorIsDiagnostic() {
        XCTAssertEqual(classify(["doctor"]), .diagnostic)
    }

    func testDoctorWithJSONIsDiagnostic() {
        XCTAssertEqual(classify(["doctor", "--json"]), .diagnostic)
    }

    // MARK: 通知APIに依存しない種別

    func testInstallIsBundleFree() {
        XCTAssertEqual(classify(["install"]), .bundleFree)
    }

    func testUninstallIsBundleFree() {
        XCTAssertEqual(classify(["uninstall", "--profile", "codex"]), .bundleFree)
    }

    func testListIsBundleFree() {
        XCTAssertEqual(classify(["list", "--json"]), .bundleFree)
    }

    func testPsIsBundleFree() {
        XCTAssertEqual(classify(["ps"]), .bundleFree)
    }

    /// 補完はバンドル未インストールでも取得できなければならない (Requirement 8.4)。
    func testCompletionIsBundleFree() {
        XCTAssertEqual(classify(["completion", "zsh"]), .bundleFree)
    }

    /// ヘルプは throw せずヘルプ用コマンドとして解決される (2026-07-30 実測)。
    /// 分類は throw の有無ではなく返ってきた型で行うため、これも bundleFree に落ちる。
    func testHelpIsBundleFree() {
        XCTAssertEqual(classify(["--help"]), .bundleFree)
        XCTAssertEqual(classify(["-h"]), .bundleFree)
    }

    func testVersionIsBundleFree() {
        XCTAssertEqual(classify(["--version"]), .bundleFree)
    }

    /// 従来の補完スクリプト生成オプションも引き継ぎ不要で完了する (Requirement 8.6)。
    func testLegacyCompletionScriptOptionIsBundleFree() {
        XCTAssertEqual(classify(["--generate-completion-script", "zsh"]), .bundleFree)
    }

    /// 解釈できない引数はバンドルへ引き継がず、その場でエラーを出させる (Requirement 11.5)。
    func testUnparsableArgumentsAreBundleFree() {
        XCTAssertEqual(classify(["bogus"]), .bundleFree)
        XCTAssertEqual(classify(["--title", "only"]), .bundleFree)
        XCTAssertEqual(classify(["completion", "powershell"]), .bundleFree)
    }

    // MARK: オプション値がサブコマンド名と一致する場合 (Requirement 11.2 / 既存不具合の回帰)

    /// 位置走査では `--title install` の "install" をサブコマンド名と誤認し、バンドル外で
    /// 通知APIに到達してクラッシュしていた。解決結果の型で判定すればこの誤認は起きない。
    func testOptionValueMatchingASubcommandNameIsNotTreatedAsThatSubcommand() {
        XCTAssertEqual(classify(["--title", "install", "--message", "m"]), .requiresBundle)
        XCTAssertEqual(classify(["--title", "ps", "--message", "m"]), .requiresBundle)
        XCTAssertEqual(classify(["--title", "t", "--message", "list"]), .requiresBundle)
        XCTAssertEqual(classify(["--subtitle", "uninstall", "--title", "t", "--message", "m"]), .requiresBundle)
    }

    // MARK: 解決処理の注入

    func testInjectedParseResultDrivesTheClassification() {
        XCTAssertEqual(
            LaunchGate.classify(arguments: [], parse: { _ in DoctorCommand() }), .diagnostic)
        XCTAssertEqual(
            LaunchGate.classify(arguments: [], parse: { _ in ListCommand() }), .bundleFree)
    }

    private struct ParseFailure: Error {}

    func testInjectedParseFailureIsBundleFree() {
        XCTAssertEqual(
            LaunchGate.classify(arguments: [], parse: { _ in throw ParseFailure() }), .bundleFree)
    }
}
