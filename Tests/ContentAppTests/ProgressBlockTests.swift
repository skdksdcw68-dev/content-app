import XCTest
@testable import ContentApp

/// "Worked for 2m 14s" -- the line a finished job's progress block says.
final class ProgressBlockTests: XCTestCase {

    func testDurationsReadTheWayClaudeSaysThem() {
        XCTAssertEqual(ProgressBlock.duration(0), "0s")
        XCTAssertEqual(ProgressBlock.duration(42.4), "42s")
        XCTAssertEqual(ProgressBlock.duration(59.6), "1m 00s", "rounds to the second before choosing the unit")
        XCTAssertEqual(ProgressBlock.duration(192), "3m 12s")
        XCTAssertEqual(ProgressBlock.duration(3_900), "1h 05m")
    }

    func testANegativeSpanIsNeverShown() {
        XCTAssertEqual(ProgressBlock.duration(-5), "0s", "clocks that disagree must not say 'Worked for -5s'")
    }
}
