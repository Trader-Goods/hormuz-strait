import XCTest
@testable import ScreenClean

final class CleaningTests: XCTestCase {
    func testMinuteStartsAtSixty() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(CleaningClock.duration)
        XCTAssertEqual(CleaningClock.remaining(at: start, end: end), 60)
        XCTAssertEqual(CleaningClock.label(60), "1:00")
    }

    func testMinuteEndsAtZero() {
        let end = Date(timeIntervalSince1970: 1_700_000_060)
        XCTAssertEqual(CleaningClock.remaining(at: end, end: end), 0)
        XCTAssertEqual(CleaningClock.remaining(at: end.addingTimeInterval(2), end: end), 0)
        XCTAssertEqual(CleaningClock.label(0), "0:00")
    }

    func testPartialSecondRoundsUp() {
        let end = Date(timeIntervalSince1970: 100)
        let almost = end.addingTimeInterval(-0.2)
        XCTAssertEqual(CleaningClock.remaining(at: almost, end: end), 1)
        XCTAssertEqual(CleaningClock.label(42), "0:42")
    }

    func testHoldIsDeliberate() {
        XCTAssertGreaterThanOrEqual(CleaningClock.holdToExit, 1)
        XCTAssertEqual(CleaningClock.panelBrightness, 0.12)
        XCTAssertLessThan(CleaningClock.panelBrightness, 0.25)
    }
}
