import XCTest

@testable import yobirin

final class YobirinCommandTests: XCTestCase {
    func testParsesWithNoArguments() throws {
        XCTAssertNoThrow(try YobirinCommand.parse([]))
    }
}
