import XCTest
@testable import ClaudeAutoResumeCore

final class ScheduledResumeDisplayTests: XCTestCase {
    func testDisplayNameUsesTitleWhenPresent() {
        XCTAssertEqual(ScheduledResumeDisplay.displayName(forTitle: "tos player"), "tos player")
    }

    func testDisplayNameFallsBackToUntitledWindowWhenTitleIsNil() {
        XCTAssertEqual(ScheduledResumeDisplay.displayName(forTitle: nil), "Untitled window")
    }

    func testLineLabelFormatsDisplayNameAndShortTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = DateComponents(year: 2026, month: 6, day: 9, hour: 14, minute: 20)
        let fireAt = calendar.date(from: components)!

        let label = ScheduledResumeDisplay.lineLabel(displayName: "tos player", fireAt: fireAt, calendar: calendar)

        XCTAssertEqual(label, "tos player — resumes at 2:20\u{202F}PM")
    }
}
