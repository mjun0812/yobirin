import XCTest

@testable import yobirin

final class TimeoutDurationTests: XCTestCase {
    // MARK: - 単位なしの指定 (Requirement 4.1: 従来どおり秒として解釈する)

    func testBareIntegerIsSeconds() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "300"), 300)
    }

    func testBareDecimalIsSeconds() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "0.5"), 0.5)
    }

    // MARK: - 単位付きの指定 (Requirement 4.2)

    func testSecondsUnit() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "90s"), 90)
    }

    func testMinutesUnit() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "5m"), 300)
    }

    func testHoursUnit() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "1h"), 3600)
    }

    // MARK: - 単位の連結 (Requirement 4.3)

    func testConcatenatedHourAndMinute() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "1h30m"), 5400)
    }

    func testConcatenatedAllUnits() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "1h30m15s"), 5415)
    }

    /// 単位の重複・順序入れ替えは合計値が一意に定まるため受理する (design.md TimeoutDuration)。
    func testDuplicatedUnitsAreAccepted() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "5m5m"), 600)
    }

    func testReorderedUnitsAreAccepted() throws {
        XCTAssertEqual(TimeoutDuration.seconds(from: "30m1h"), 5400)
    }

    // MARK: - 解釈できない指定 (Requirement 4.4)

    func testRejectsNonNumericValue() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "abc"))
    }

    func testRejectsUnknownUnit() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "5x"))
    }

    func testRejectsEmptyValue() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: ""))
    }

    func testRejectsUnitWithoutNumber() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "s"))
    }

    func testRejectsTrailingNumberWithoutUnit() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "5m30"))
    }

    /// 単位付きは正の整数のみを受け付ける (design.md の文法定義)。
    func testRejectsDecimalWithUnit() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "1.5m"))
    }

    /// 単位は小文字のみ受け付ける (design.md の文法定義)。大文字を黙って受理すると、
    /// ヘルプに書く書式と実際の受理範囲が食い違う。
    func testRejectsUppercaseUnit() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "5M"))
        XCTAssertNil(TimeoutDuration.seconds(from: "1H"))
    }

    func testRejectsSurroundingWhitespace() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: " 5m"))
        XCTAssertNil(TimeoutDuration.seconds(from: "5 m"))
    }

    /// `Double("inf")` は無限大として解釈され `> 0` も満たすため、有限性の検査がないと通過してしまう。
    func testRejectsInfinity() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "inf"))
    }

    func testRejectsNaN() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "nan"))
    }

    // MARK: - 正の値でない指定 (Requirement 4.5)

    func testRejectsZero() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "0"))
    }

    func testRejectsZeroWithUnit() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "0m"))
    }

    func testRejectsNegativeValue() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "-5"))
    }

    func testRejectsNegativeValueWithUnit() throws {
        XCTAssertNil(TimeoutDuration.seconds(from: "-1h"))
    }

    /// 桁数の多い入力でIntのオーバーフロー (Swiftでは実行時トラップ) を起こさないこと。
    /// 丸め方が処理系依存になるため具体値は固定せず、有限の正値が返ることのみを検証する。
    func testVeryLargeValueDoesNotTrap() throws {
        let result = TimeoutDuration.seconds(from: "99999999999999999999h")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.isFinite, true)
    }
}
