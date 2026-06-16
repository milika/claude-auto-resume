import XCTest
@testable import ClaudeAutoResumeCore

final class ResumeStaggeringTests: XCTestCase {
    func testSingleEntryFiresAtItsOwnResetTime() {
        let resetAt = Date(timeIntervalSince1970: 1000)
        let result = ResumeStaggering.staggeredFireTimes(
            for: [(windowID: "win-1", resetAt: resetAt)], minimumGap: 5)

        XCTAssertEqual(result, [.init(windowID: "win-1", fireAt: resetAt)])
    }

    func testOverlappingEntriesAreSpacedByMinimumGap() {
        let t = Date(timeIntervalSince1970: 1000)
        let result = ResumeStaggering.staggeredFireTimes(
            for: [
                (windowID: "win-1", resetAt: t),
                (windowID: "win-2", resetAt: t.addingTimeInterval(1)),
                (windowID: "win-3", resetAt: t.addingTimeInterval(2))
            ],
            minimumGap: 5)

        XCTAssertEqual(result, [
            .init(windowID: "win-1", fireAt: t),
            .init(windowID: "win-2", fireAt: t.addingTimeInterval(5)),
            .init(windowID: "win-3", fireAt: t.addingTimeInterval(10))
        ])
    }

    func testFarApartEntriesAreNotShifted() {
        let t = Date(timeIntervalSince1970: 1000)
        let result = ResumeStaggering.staggeredFireTimes(
            for: [
                (windowID: "win-1", resetAt: t),
                (windowID: "win-2", resetAt: t.addingTimeInterval(3600))
            ],
            minimumGap: 5)

        XCTAssertEqual(result, [
            .init(windowID: "win-1", fireAt: t),
            .init(windowID: "win-2", fireAt: t.addingTimeInterval(3600))
        ])
    }
}
