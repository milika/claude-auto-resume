import XCTest
@testable import ClaudeAutoResumeCore

final class KofiNagPolicyTests: XCTestCase {
    private let firstLaunch = Date(timeIntervalSince1970: 1_700_000_000)
    private let oneDay: TimeInterval = 24 * 3600

    func testDoesNotShowBeforeUsageThreshold() {
        let now = firstLaunch.addingTimeInterval(4 * oneDay)
        XCTAssertFalse(KofiNagPolicy.shouldShow(now: now, firstLaunchDate: firstLaunch,
                                                 lastShownDate: nil, dismissedPermanently: false))
    }

    func testShowsAtThresholdWhenNeverShownAndNotDismissed() {
        let now = firstLaunch.addingTimeInterval(5 * oneDay)
        XCTAssertTrue(KofiNagPolicy.shouldShow(now: now, firstLaunchDate: firstLaunch,
                                                lastShownDate: nil, dismissedPermanently: false))
    }

    func testDoesNotShowAgainOnTheSameDayItWasShown() {
        let now = firstLaunch.addingTimeInterval(5 * oneDay)
        XCTAssertFalse(KofiNagPolicy.shouldShow(now: now, firstLaunchDate: firstLaunch,
                                                 lastShownDate: now, dismissedPermanently: false))
    }

    func testShowsAgainOnANewDayAfterLastShown() {
        let now = firstLaunch.addingTimeInterval(6 * oneDay)
        let lastShown = firstLaunch.addingTimeInterval(5 * oneDay)
        XCTAssertTrue(KofiNagPolicy.shouldShow(now: now, firstLaunchDate: firstLaunch,
                                                lastShownDate: lastShown, dismissedPermanently: false))
    }

    func testNeverShowsWhenDismissedPermanently() {
        let now = firstLaunch.addingTimeInterval(10 * oneDay)
        XCTAssertFalse(KofiNagPolicy.shouldShow(now: now, firstLaunchDate: firstLaunch,
                                                 lastShownDate: nil, dismissedPermanently: true))
    }
}
