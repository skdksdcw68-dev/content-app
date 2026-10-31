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

    /// One plain line, the way Claude shows it: the step it is on and the
    /// clock while it works, "Worked for" when it is done.
    func testTheLineSaysTheStepWhileWorkingAndTheTimeWhenDone() {
        let start = Date(timeIntervalSince1970: 1_000)
        let steps = ["📝 Planning a 15-second story…", "🖼️ Making picture 3 of 6\nwith more after it"]
        XCTAssertEqual(
            ProgressBlock.headline(steps: steps, live: true, started: start, ended: nil, now: start.addingTimeInterval(42)),
            "Making picture 3 of 6 · 42s",
            "only the step's first line, without its emoji"
        )
        XCTAssertEqual(
            ProgressBlock.headline(steps: steps, live: false, started: start, ended: start.addingTimeInterval(192), now: .now),
            "Worked for 3m 12s"
        )
        XCTAssertEqual(ProgressBlock.headline(steps: steps, live: false, started: nil, ended: nil, now: .now), "Done in 2 steps")
    }
}
