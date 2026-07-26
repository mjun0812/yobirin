import XCTest

@testable import yobirin

final class OutputTests: XCTestCase {
    // MARK: - JSON generation per result kind (design.md Data Models > 出力JSON契約)

    func testClickedJSON() throws {
        let output = ResultOutput(result: .clicked, deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"clicked\"}")
    }

    func testDismissedJSON() throws {
        let output = ResultOutput(result: .dismissed, deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"dismissed\"}")
    }

    func testTimeoutJSON() throws {
        let output = ResultOutput(result: .timeout, deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"timeout\"}")
    }

    func testActionJSON() throws {
        let output = ResultOutput(result: .action(label: "Open", index: 0), deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"action\",\"action\":\"Open\",\"actionIndex\":0}")
    }

    func testActionJSONUsesGivenIndexNotZero() throws {
        let output = ResultOutput(result: .action(label: "Dismiss", index: 1), deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"action\",\"action\":\"Dismiss\",\"actionIndex\":1}")
    }

    func testRepliedJSON() throws {
        let output = ResultOutput(result: .replied(text: "hello"), deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"replied\",\"text\":\"hello\"}")
    }

    // MARK: - deliveredAt is optional and attachable to any result

    func testClickedJSONWithDeliveredAt() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let expectedDate = ISO8601DateFormatter().string(from: date)
        let output = ResultOutput(result: .clicked, deliveredAt: date)
        XCTAssertEqual(
            output.jsonString(),
            "{\"result\":\"clicked\",\"deliveredAt\":\"\(expectedDate)\"}"
        )
    }

    func testDismissedJSONWithDeliveredAtKeepsDeliveredAtLast() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let expectedDate = ISO8601DateFormatter().string(from: date)
        let output = ResultOutput(result: .dismissed, deliveredAt: date)
        XCTAssertEqual(
            output.jsonString(),
            "{\"result\":\"dismissed\",\"deliveredAt\":\"\(expectedDate)\"}"
        )
    }

    func testActionJSONWithDeliveredAtOrdersDeliveredAtLast() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let expectedDate = ISO8601DateFormatter().string(from: date)
        let output = ResultOutput(result: .action(label: "Open", index: 0), deliveredAt: date)
        XCTAssertEqual(
            output.jsonString(),
            "{\"result\":\"action\",\"action\":\"Open\",\"actionIndex\":0,\"deliveredAt\":\"\(expectedDate)\"}"
        )
    }

    // MARK: - Japanese text / UTF-8 correctness

    func testActionJSONPreservesJapaneseLabel() throws {
        let output = ResultOutput(result: .action(label: "開く", index: 0), deliveredAt: nil)
        let json = output.jsonString()
        XCTAssertEqual(json, "{\"result\":\"action\",\"action\":\"開く\",\"actionIndex\":0}")

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["action"] as? String, "開く")
    }

    func testRepliedJSONPreservesJapaneseTextAndEscapesQuotes() throws {
        let text = "彼は\"了解\"と返信した"
        let output = ResultOutput(result: .replied(text: text), deliveredAt: nil)
        let json = output.jsonString()

        // Structural verification: valid JSON that round-trips to the exact original text,
        // including the embedded double quotes that must be escaped.
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["result"] as? String, "replied")
        XCTAssertEqual(parsed?["text"] as? String, text)
    }

    // MARK: - Structural validation (not just literal string matches)

    func testAllResultKindsProduceParsableJSONWithExpectedResultField() throws {
        let cases: [(ResultOutput, String)] = [
            (ResultOutput(result: .clicked, deliveredAt: nil), "clicked"),
            (ResultOutput(result: .dismissed, deliveredAt: nil), "dismissed"),
            (ResultOutput(result: .timeout, deliveredAt: nil), "timeout"),
            (ResultOutput(result: .action(label: "Open", index: 2), deliveredAt: nil), "action"),
            (ResultOutput(result: .replied(text: "hi"), deliveredAt: nil), "replied"),
        ]

        for (output, expectedResult) in cases {
            let json = output.jsonString()
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            XCTAssertEqual(parsed?["result"] as? String, expectedResult)
        }
    }

    // MARK: - Output destination / exit code decision (design.md Error Handling > 終了コード)

    func testForResultProducesStdoutAndExitZero() throws {
        let output = ResultOutput(result: .clicked, deliveredAt: nil)
        let emitted = ResultEmitter.forResult(output)

        XCTAssertEqual(emitted.destination, .stdout)
        XCTAssertEqual(emitted.exitCode, 0)
        XCTAssertEqual(emitted.text, output.jsonString())
    }

    func testForPermissionDeniedProducesStderrAndExitTwoWithNoJSON() throws {
        let emitted = ResultEmitter.forPermissionDenied(reason: "通知許可がありません")

        XCTAssertEqual(emitted.destination, .stderr)
        XCTAssertEqual(emitted.exitCode, 2)
        XCTAssertEqual(emitted.text, "通知許可がありません")
        XCTAssertFalse(emitted.text.contains("\"result\""))
    }

    func testForEnvironmentErrorProducesStderrAndNonZeroNonTwoExitCodeWithNoJSON() throws {
        let emitted = ResultEmitter.forEnvironmentError("環境エラーが発生しました")

        XCTAssertEqual(emitted.destination, .stderr)
        XCTAssertNotEqual(emitted.exitCode, 0)
        XCTAssertNotEqual(emitted.exitCode, 2)
        XCTAssertEqual(emitted.text, "環境エラーが発生しました")
        XCTAssertFalse(emitted.text.contains("\"result\""))
    }
}
