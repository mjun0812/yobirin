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

    func testCanceledJSON() throws {
        let output = ResultOutput(result: .canceled, deliveredAt: nil)
        XCTAssertEqual(output.jsonString(), "{\"result\":\"canceled\"}")
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
            (ResultOutput(result: .canceled, deliveredAt: nil), "canceled"),
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
        XCTAssertFalse(emitted.text?.contains("\"result\"") ?? false)
    }

    func testForEnvironmentErrorProducesStderrAndNonZeroNonTwoExitCodeWithNoJSON() throws {
        let emitted = ResultEmitter.forEnvironmentError("環境エラーが発生しました")

        XCTAssertEqual(emitted.destination, .stderr)
        XCTAssertNotEqual(emitted.exitCode, 0)
        XCTAssertNotEqual(emitted.exitCode, 2)
        XCTAssertEqual(emitted.text, "環境エラーが発生しました")
        XCTAssertFalse(emitted.text?.contains("\"result\"") ?? false)
    }
}

// MARK: - 出力対象フィールドと値の取り出し (Requirements 2.2, 2.5, 2.7)

final class PrintFieldTests: XCTestCase {
    func testAcceptsExactlyTheFourDocumentedFields() throws {
        XCTAssertEqual(
            Set(PrintField.allCases.map(\.rawValue)),
            ["result", "action", "actionIndex", "text"])
    }

    /// 引数解析の段階で4種以外が拒否される (Requirement 2.3 の前提)。
    func testRejectsUnknownFieldAtArgumentParsing() throws {
        XCTAssertNil(PrintField(argument: "deliveredAt"))
        XCTAssertNil(PrintField(argument: "RESULT"))
        XCTAssertNil(PrintField(argument: ""))
    }

    func testAcceptsEachDocumentedFieldAsArgument() throws {
        for field in PrintField.allCases {
            XCTAssertEqual(PrintField(argument: field.rawValue), field)
        }
    }
}

final class ResultOutputValueTests: XCTestCase {
    private func value(_ result: NotificationResult, _ field: PrintField) -> String? {
        ResultOutput(result: result, deliveredAt: nil).value(for: field)
    }

    // MARK: result はすべての種別で存在する

    func testResultFieldForEveryKind() throws {
        XCTAssertEqual(value(.clicked, .result), "clicked")
        XCTAssertEqual(value(.action(label: "Open", index: 0), .result), "action")
        XCTAssertEqual(value(.replied(text: "hi"), .result), "replied")
        XCTAssertEqual(value(.dismissed, .result), "dismissed")
        XCTAssertEqual(value(.timeout, .result), "timeout")
        XCTAssertEqual(value(.canceled, .result), "canceled")
    }

    // MARK: action / actionIndex は action のみ

    func testActionFieldsOnActionResult() throws {
        let result = NotificationResult.action(label: "Approve", index: 2)
        XCTAssertEqual(value(result, .action), "Approve")
        XCTAssertEqual(value(result, .actionIndex), "2")
    }

    func testActionFieldsAreAbsentOnOtherKinds() throws {
        for result in [NotificationResult.clicked, .replied(text: "hi"), .dismissed, .timeout, .canceled] {
            XCTAssertNil(value(result, .action), "\(result)")
            XCTAssertNil(value(result, .actionIndex), "\(result)")
        }
    }

    // MARK: text は replied のみ

    func testTextFieldOnRepliedResult() throws {
        XCTAssertEqual(value(.replied(text: "reply body"), .text), "reply body")
    }

    func testTextFieldIsAbsentOnOtherKinds() throws {
        for result in [
            NotificationResult.clicked, .action(label: "A", index: 0), .dismissed, .timeout, .canceled,
        ] {
            XCTAssertNil(value(result, .text), "\(result)")
        }
    }

    // MARK: 生の文字列 (Requirement 2.5)

    /// JSONのクォート・エスケープを施さない。引用符や改行を含む返信がそのまま出る。
    func testValuesAreRawStringsWithoutJSONEscaping() throws {
        XCTAssertEqual(value(.replied(text: "say \"hi\"\nplease"), .text), "say \"hi\"\nplease")
        XCTAssertEqual(value(.action(label: "は い", index: 0), .action), "は い")
    }
}

// MARK: - 出力方針 (Requirements 1, 2, 3)

final class OutputPolicyTests: XCTestCase {
    func testDefaultPolicyKeepsTheExistingBehavior() throws {
        XCTAssertEqual(OutputPolicy.default, OutputPolicy(exitCodeEnabled: false, printField: nil))
    }
}

// MARK: - 結果種別からの終了コード (Requirements 1.1〜1.4, 1.6, 1.7)

final class ResultExitCodeTests: XCTestCase {
    func testClickedAndRepliedExitZero() throws {
        XCTAssertEqual(ResultEmitter.exitCode(for: .clicked), 0)
        XCTAssertEqual(ResultEmitter.exitCode(for: .replied(text: "hi")), 0)
    }

    func testActionExitsBasePlusIndex() throws {
        XCTAssertEqual(ResultEmitter.exitCode(for: .action(label: "A", index: 0)), 10)
        XCTAssertEqual(ResultEmitter.exitCode(for: .action(label: "B", index: 1)), 11)
        XCTAssertEqual(ResultEmitter.exitCode(for: .action(label: "C", index: 5)), 15)
    }

    func testDismissedExitsThree() throws {
        XCTAssertEqual(ResultEmitter.exitCode(for: .dismissed), 3)
    }

    func testTimeoutExitsFour() throws {
        XCTAssertEqual(ResultEmitter.exitCode(for: .timeout), 4)
    }

    /// canceled は5 (design.md 終了コード表、Requirement 3.2)。
    func testCanceledExitsFive() throws {
        XCTAssertEqual(ResultEmitter.exitCode(for: .canceled), 5)
    }

    /// 既存の予約コード (未許可2 / 環境エラー1) と衝突しないこと (Requirements 1.6, 1.7)。
    /// アクションの index は category 登録時に採番される小さな値だが、上限は仕様に無いため
    /// 広い範囲で確かめる。
    func testNeverReturnsTheReservedExitCodes() throws {
        var codes: [Int32] = [
            ResultEmitter.exitCode(for: .clicked),
            ResultEmitter.exitCode(for: .replied(text: "t")),
            ResultEmitter.exitCode(for: .dismissed),
            ResultEmitter.exitCode(for: .timeout),
            ResultEmitter.exitCode(for: .canceled),
        ]
        for index in 0..<100 {
            codes.append(ResultEmitter.exitCode(for: .action(label: "L", index: index)))
        }
        XCTAssertFalse(codes.contains(ResultEmitter.permissionDeniedExitCode))
        XCTAssertFalse(codes.contains(ResultEmitter.environmentErrorExitCode))
    }

    /// canceled が予約コード (1, 2) にも使用済みコード (3, 4, 10+) にも衝突しないこと
    /// (Requirement 3.7)。
    func testCanceledExitCodeDoesNotCollideWithReservedOrUsedCodes() throws {
        XCTAssertNotEqual(ResultEmitter.canceledExitCode, ResultEmitter.permissionDeniedExitCode)
        XCTAssertNotEqual(ResultEmitter.canceledExitCode, ResultEmitter.environmentErrorExitCode)
        XCTAssertNotEqual(ResultEmitter.canceledExitCode, ResultEmitter.dismissedExitCode)
        XCTAssertNotEqual(ResultEmitter.canceledExitCode, ResultEmitter.timeoutExitCode)
        XCTAssertLessThan(ResultEmitter.canceledExitCode, ResultEmitter.actionExitCodeBase)
    }

    /// 終了コードの数値は ResultEmitter の定数として一元管理する (structure.md)。
    func testCodesAreExposedAsNamedConstants() throws {
        XCTAssertEqual(ResultEmitter.dismissedExitCode, 3)
        XCTAssertEqual(ResultEmitter.timeoutExitCode, 4)
        XCTAssertEqual(ResultEmitter.canceledExitCode, 5)
        XCTAssertEqual(ResultEmitter.actionExitCodeBase, 10)
    }
}

// MARK: - 出力方針に従う出力決定 (Requirements 1.5, 1.8, 2.1, 2.4, 2.6, 3.1)

final class ResultEmitterPolicyTests: XCTestCase {
    private func emit(
        _ result: NotificationResult,
        exitCode: Bool = false,
        print field: PrintField? = nil
    ) -> EmittedOutput {
        ResultEmitter.forResult(
            ResultOutput(result: result, deliveredAt: nil),
            policy: OutputPolicy(exitCodeEnabled: exitCode, printField: field))
    }

    // MARK: 既定方針は変更前と完全に一致する (Requirements 1.5, 2.6)

    func testDefaultPolicyMatchesThePreviousBehaviorForEveryKind() throws {
        let results: [NotificationResult] = [
            .clicked, .action(label: "Open", index: 1), .replied(text: "hi"), .dismissed, .timeout,
            .canceled,
        ]
        for result in results {
            let output = ResultOutput(result: result, deliveredAt: nil)
            let emitted = ResultEmitter.forResult(output)
            XCTAssertEqual(emitted.destination, .stdout, "\(result)")
            XCTAssertEqual(emitted.text, output.jsonString(), "\(result)")
            XCTAssertEqual(emitted.exitCode, 0, "\(result)")
        }
    }

    /// policy 省略と .default 明示は同じ結果になる (既定引数の回帰固定)。
    func testOmittedPolicyEqualsExplicitDefault() throws {
        let output = ResultOutput(result: .dismissed, deliveredAt: nil)
        XCTAssertEqual(ResultEmitter.forResult(output), ResultEmitter.forResult(output, policy: .default))
    }

    // MARK: --exit-code のみ (Requirements 1.1〜1.4, 1.8)

    func testExitCodeOnlyChangesTheExitCodeButNotTheOutput() throws {
        let emitted = emit(.dismissed, exitCode: true)
        XCTAssertEqual(emitted.text, ResultOutput(result: .dismissed, deliveredAt: nil).jsonString())
        XCTAssertEqual(emitted.exitCode, 3)
    }

    func testExitCodeReflectsActionIndex() throws {
        XCTAssertEqual(emit(.action(label: "B", index: 1), exitCode: true).exitCode, 11)
    }

    // MARK: --print のみ (Requirements 2.1, 2.4)

    func testPrintReplacesTheJSONWithTheRawValue() throws {
        let emitted = emit(.replied(text: "the reply"), print: .text)
        XCTAssertEqual(emitted.text, "the reply")
        XCTAssertEqual(emitted.exitCode, 0)
        XCTAssertEqual(emitted.destination, .stdout)
    }

    /// フィールドが結果種別に存在しないとき、text は nil (出力なし)。空文字列とは区別される
    /// (Requirement 2.4: 空行も書かない)。終了コードは方針に従い決まる。
    func testMissingFieldProducesNoOutputAtAll() throws {
        let emitted = emit(.dismissed, print: .text)
        XCTAssertNil(emitted.text)
        XCTAssertEqual(emitted.exitCode, 0)
    }

    /// 空の返信は「出力なし」ではなく「空の値の出力」。nil と空文字列の区別が保たれる。
    func testEmptyReplyIsAnEmptyValueNotAnAbsentOne() throws {
        XCTAssertEqual(emit(.replied(text: ""), print: .text).text, "")
    }

    // MARK: 併用 (Requirement 3.1)

    func testCombinedPolicyPrintsTheRawValueAndSetsTheExitCode() throws {
        let emitted = emit(.action(label: "Approve", index: 0), exitCode: true, print: .action)
        XCTAssertEqual(emitted.text, "Approve")
        XCTAssertEqual(emitted.exitCode, 10)
    }

    func testCombinedPolicyWithMissingFieldStillSetsTheExitCode() throws {
        let emitted = emit(.timeout, exitCode: true, print: .text)
        XCTAssertNil(emitted.text)
        XCTAssertEqual(emitted.exitCode, 4)
    }

    // MARK: canceled の出力方針 (Requirements 3.1〜3.5)

    /// `--exit-code` 未指定時は既存どおり 0 (Requirement 3.3)。
    func testCanceledDefaultPolicyOutputsJSONAndExitsZero() throws {
        let output = ResultOutput(result: .canceled, deliveredAt: nil)
        let emitted = ResultEmitter.forResult(output)
        XCTAssertEqual(emitted.text, output.jsonString())
        XCTAssertEqual(emitted.exitCode, 0)
    }

    /// `--exit-code` 指定時は 5 (Requirement 3.2)。
    func testCanceledWithExitCodeEnabledExitsFive() throws {
        XCTAssertEqual(emit(.canceled, exitCode: true).exitCode, 5)
    }

    /// `--print result` は `canceled` を生の文字列で返す (Requirement 3.4)。
    func testCanceledPrintResultOutputsCanceled() throws {
        XCTAssertEqual(emit(.canceled, print: .result).text, "canceled")
    }

    /// `--print action` / `actionIndex` / `text` は出力なし + 結果に対応する終了コード
    /// (Requirement 3.5)。
    func testCanceledPrintOtherFieldsProducesNoOutputButKeepsExitCode() throws {
        for field: PrintField in [.action, .actionIndex, .text] {
            let emitted = emit(.canceled, exitCode: true, print: field)
            XCTAssertNil(emitted.text, "\(field)")
            XCTAssertEqual(emitted.exitCode, 5, "\(field)")
        }
    }

    // MARK: 出力方針は許可なし・環境エラーの経路に影響しない (Requirements 1.6, 1.7)

    func testPermissionDeniedAndEnvironmentErrorAreUnaffected() throws {
        XCTAssertEqual(ResultEmitter.forPermissionDenied(reason: "denied").exitCode, 2)
        XCTAssertEqual(ResultEmitter.forEnvironmentError("broken").exitCode, 1)
    }
}

private struct NoopCancellable: Cancellable {
    func cancel() {}
}

// MARK: - text が nil のとき書き込まない (Requirement 2.4)

final class ExitCoordinatorNilTextTests: XCTestCase {
    func testNilTextWritesNothingButStillExitsWithTheCode() throws {
        var writes: [(OutputDestination, String)] = []
        var scheduled: [() -> Void] = []
        var exitCodes: [Int32] = []

        ExitCoordinator.finish(
            EmittedOutput(destination: .stdout, text: nil, exitCode: 4),
            writer: { writes.append(($0, $1)) },
            scheduler: { _, work in
                scheduled.append(work)
                return NoopCancellable()
            },
            exit: { exitCodes.append($0) }
        )
        for work in scheduled { work() }

        XCTAssertTrue(writes.isEmpty, "nil は出力なしを意味する。空行も書かない")
        XCTAssertEqual(exitCodes, [4])
    }

    func testEmptyTextStillWritesAnEmptyLine() throws {
        var writes: [(OutputDestination, String)] = []
        var scheduled: [() -> Void] = []

        ExitCoordinator.finish(
            EmittedOutput(destination: .stdout, text: "", exitCode: 0),
            writer: { writes.append(($0, $1)) },
            scheduler: { _, work in
                scheduled.append(work)
                return NoopCancellable()
            },
            exit: { _ in }
        )
        for work in scheduled { work() }

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.1, "")
    }
}
