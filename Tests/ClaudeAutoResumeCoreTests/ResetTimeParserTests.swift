import XCTest
@testable import ClaudeAutoResumeCore

final class ResetTimeParserTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    func testParsesAbsoluteTimeLaterToday() {
        // "now" is 1:00 PM UTC on 2026-06-07
        let now = dateAt(hour: 13, minute: 0, on: 7)
        let result = ResetTimeParser.parse("You've reached your usage limit. Resets at 3:00 PM.",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 15, minute: 0, on: 7))
    }

    func testParsesAbsoluteTimeInThePastReturnsThatPastTime() {
        // "now" is 4:00 PM UTC; "resets at 3:00 PM" means the reset already
        // happened an hour ago — a stale banner, not a tomorrow target.
        let now = dateAt(hour: 16, minute: 0, on: 7)
        let result = ResetTimeParser.parse("Resets at 3:00 PM.", now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 15, minute: 0, on: 7))
    }

    func testParsesStaleAbsoluteTimeWithTimezoneAnnotationReturnsPastTimeNotTomorrow() {
        // "now" is 12:46 PM UTC on 2026-06-07 — after the reset time in the
        // banner has already passed. A banner still showing "resets 12:10pm
        // (UTC)" at this point means the limit already cleared ~36 minutes
        // ago, not that it resets again tomorrow at the same time.
        let now = dateAt(hour: 12, minute: 46, on: 7)
        let result = ResetTimeParser.parse("You've hit your session limit · resets 12:10pm (UTC)",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 12, minute: 10, on: 7))
    }

    func testParsesLowercaseMeridiemWithoutAtKeyword() {
        let now = dateAt(hour: 13, minute: 0, on: 7)
        let result = ResetTimeParser.parse("Resets 3:00pm.", now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 15, minute: 0, on: 7))
    }

    func testParsesAbsoluteTimeWithTimezoneAnnotationInterpretsInThatZone() {
        // "now" is 1:00 AM UTC on 2026-06-07. The banner's IANA timezone
        // annotation tells the parser to interpret "2:20pm" in that zone, not
        // the calendar's, so "2:20pm (UTC)" is 14:20 UTC — later that day.
        let now = dateAt(hour: 1, minute: 0, on: 7)
        let result = ResetTimeParser.parse("You've hit your session limit · resets 2:20pm (UTC)",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 14, minute: 20, on: 7))
    }

    func testParsesHourOnlyMeridiemWithTimezoneAnnotation() {
        // Real-world toast text from Claude Desktop's "View details" panel:
        // "resets 3pm (UTC)" — hour only, no minutes. "now" is 1:00 AM UTC
        // on 2026-06-07, so "3pm (UTC)" is 15:00 UTC — later that day.
        let now = dateAt(hour: 1, minute: 0, on: 7)
        let result = ResetTimeParser.parse("You've hit your session limit · resets 3pm (UTC)",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 15, minute: 0, on: 7))
    }

    func testParsesRelativeHours() {
        let now = dateAt(hour: 13, minute: 0, on: 7)
        let result = ResetTimeParser.parse("You can try again in 2 hours.", now: now, calendar: calendar)
        XCTAssertEqual(result, now.addingTimeInterval(2 * 3600))
    }

    func testParsesRelativeMinutes() {
        let now = dateAt(hour: 13, minute: 0, on: 7)
        let result = ResetTimeParser.parse("Try again in 45 minutes.", now: now, calendar: calendar)
        XCTAssertEqual(result, now.addingTimeInterval(45 * 60))
    }

    func testReturnsNilForUnrecognizedText() {
        let now = dateAt(hour: 13, minute: 0, on: 7)
        XCTAssertNil(ResetTimeParser.parse("Hello, how can I help you today?", now: now, calendar: calendar))
    }

    func testParsesAbsoluteDateWithWeekdayMonthDayTime() {
        // "now" is 9:00 AM UTC on 2026-06-07; banner shows the new Claude Code
        // CLI format with weekday, month, day, and time all spelled out.
        let now = dateAt(hour: 9, minute: 0, on: 7)
        let result = ResetTimeParser.parse("Usage limit reached · Resets Fri, Jun 12, 12:40 AM",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 0, minute: 40, on: 12))
    }

    func testParsesAbsoluteDateWithoutWeekdayPrefix() {
        let now = dateAt(hour: 9, minute: 0, on: 7)
        let result = ResetTimeParser.parse("Resets Jun 12, 12:40 AM",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 0, minute: 40, on: 12))
    }

    func testParsesAbsoluteDateWithSingleDigitDayAndHour() {
        let now = dateAt(hour: 9, minute: 0, on: 1)
        let result = ResetTimeParser.parse("Resets Mon, Jun 1, 9:05 PM",
                                            now: now, calendar: calendar)
        XCTAssertEqual(result, dateAt(hour: 21, minute: 5, on: 1))
    }

    private func dateAt(hour: Int, minute: Int, on day: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }
}
