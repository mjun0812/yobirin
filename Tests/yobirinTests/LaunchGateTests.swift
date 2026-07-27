import XCTest

@testable import yobirin

/// 起動ゲートの判定 (design.md 起動ゲートとインストールのフロー、Requirements 12.1, 12.2, 12.3)。
///
/// `LaunchGate.decide` は「バンドル外検知 → バンドル内なら引数なしガード→ルーティング /
/// バンドル外ならコマンド種別で分岐」を純粋関数として提供する。`isOutsideBundle` はBool注入
/// のため、6.1のxctestホスト固有事情 (`Bundle.main.bundleIdentifier` が非nil) に影響されず
/// 「バンドル外」を明示的にシミュレートできる。
final class LaunchGateTests: XCTestCase {
    // MARK: - Inside bundle: argumentless guard → routing (unchanged from LaunchGuard)

    func testInsideBundleWithNoArgumentsSweepsOrphans() {
        XCTAssertEqual(LaunchGate.decide(arguments: [], isOutsideBundle: false), .sweepOrphans)
    }

    func testInsideBundleWithExecutableNameOnlySweepsOrphans() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin"], isOutsideBundle: false), .sweepOrphans)
    }

    func testInsideBundleWithNotificationArgumentsRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(
                arguments: ["/path/to/yobirin", "--title", "t", "--message", "m"], isOutsideBundle: false),
            .runCLI)
    }

    func testInsideBundleWithHelpRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "--help"], isOutsideBundle: false), .runCLI)
    }

    func testInsideBundleWithInstallRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "install"], isOutsideBundle: false), .runCLI)
    }

    // MARK: - Outside bundle: notification requests / argumentless launch are guided, not crashed (Requirements 12.2, 12.3)

    func testOutsideBundleWithNoArgumentsGuidesInstall() {
        XCTAssertEqual(LaunchGate.decide(arguments: [], isOutsideBundle: true), .guideInstall)
    }

    func testOutsideBundleWithExecutableNameOnlyGuidesInstall() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin"], isOutsideBundle: true), .guideInstall)
    }

    func testOutsideBundleWithNotificationArgumentsGuidesInstall() {
        XCTAssertEqual(
            LaunchGate.decide(
                arguments: ["/path/to/yobirin", "--title", "t", "--message", "m"], isOutsideBundle: true),
            .guideInstall)
    }

    func testOutsideBundleWithNotifySubcommandGuidesInstall() {
        // "notify" は先頭の非フラグ引数だが "install" ではないため、通知系として案内される。
        XCTAssertEqual(
            LaunchGate.decide(
                arguments: ["/path/to/yobirin", "notify", "--title", "t"], isOutsideBundle: true),
            .guideInstall)
    }

    // MARK: - Outside bundle: install and help proceed without touching notification types (Requirement 12.1)

    func testOutsideBundleWithInstallRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "install"], isOutsideBundle: true), .runCLI)
    }

    func testOutsideBundleWithInstallAndTrailingOptionsRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(
                arguments: ["/path/to/yobirin", "install", "--profile", "claude"], isOutsideBundle: true),
            .runCLI)
    }

    func testOutsideBundleWithListRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "list"], isOutsideBundle: true), .runCLI)
    }

    func testOutsideBundleWithListJSONRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "list", "--json"], isOutsideBundle: true),
            .runCLI)
    }

    func testOutsideBundleWithLeadingBareFlagBeforeInstallStillRunsCLI() {
        // "install" の判定は「実行ファイル名を除く最初の"非フラグ"引数」であり、
        // 先行する値を取らないフラグ (例: `--verbose`) の有無に左右されない。
        // (値を取るオプション、例: `--profile claude` の "claude" は非フラグ引数として
        // カウントされるため、この判定は「先頭からフラグ以外の値を持つオプション」を
        // 挟んだ場合までは保証しない。)
        XCTAssertEqual(
            LaunchGate.decide(
                arguments: ["/path/to/yobirin", "--verbose", "install"], isOutsideBundle: true),
            .runCLI)
    }

    func testOutsideBundleWithHelpRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "--help"], isOutsideBundle: true), .runCLI)
    }

    func testOutsideBundleWithShortHelpRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "-h"], isOutsideBundle: true), .runCLI)
    }

    func testOutsideBundleWithVersionRunsCLI() {
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "--version"], isOutsideBundle: true), .runCLI)
    }

    func testOutsideBundleWithHelpAfterSubcommandRunsCLI() {
        // --help / -h / --version は引数列のどこにあっても検出される。
        XCTAssertEqual(
            LaunchGate.decide(arguments: ["/path/to/yobirin", "notify", "--help"], isOutsideBundle: true),
            .runCLI)
    }
}
