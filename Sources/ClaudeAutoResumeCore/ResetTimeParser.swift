import Foundation

public enum ResetTimeParser {
    /// Extracts an absolute reset `Date` from a rate-limit banner's text.
    /// Returns `nil` if no recognizable reset-time phrase is found.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        if let date = parseAbsoluteDate(text, now: now, calendar: calendar) {
            return date
        }
        if let date = parseAbsoluteTime(text, now: now, calendar: calendar) {
            return date
        }
        if let date = parseRelativeDuration(text, now: now) {
            return date
        }
        return nil
    }

    private static let monthAbbreviations: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Converts a 12-hour clock hour + meridiem ("AM"/"PM") to 24-hour form.
    private static func hour24(from hour: Int, meridiem: String) -> Int {
        if meridiem == "PM" && hour != 12 { return hour + 12 }
        if meridiem == "AM" && hour == 12 { return 0 }
        return hour
    }

    /// Matches phrases like "Resets Fri, Jun 12, 12:40 AM" or
    /// "Resets Jun 12, 12:40 AM" — the new Claude Code CLI usage-limit banner,
    /// which shows the full reset date+time up front (no "View details" step
    /// needed). The weekday prefix is optional and, if present, is consumed
    /// but not validated. The year is taken from `now`'s year.
    ///
    /// Known minor limitation: a Dec 31 -> Jan 1 rollover isn't specially
    /// handled, so a date read right at the year boundary may resolve to a
    /// date in the past. Consistent with the "a past time means the limit
    /// already cleared, resume now" philosophy below for the time-only
    /// format — a once-a-year edge case not worth extra complexity.
    private static func parseAbsoluteDate(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let pattern = #"(?i)resets?\s+(?:[A-Za-z]+,\s*)?([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{1,2}):(\d{2})\s*(AM|PM)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let monthRange = Range(match.range(at: 1), in: text),
              let dayRange = Range(match.range(at: 2), in: text),
              let hourRange = Range(match.range(at: 3), in: text),
              let minuteRange = Range(match.range(at: 4), in: text),
              let meridiemRange = Range(match.range(at: 5), in: text),
              let month = monthAbbreviations[String(text[monthRange].prefix(3)).lowercased()],
              let day = Int(text[dayRange]),
              var hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange])
        else { return nil }

        let meridiem = text[meridiemRange].uppercased()
        hour = hour24(from: hour, meridiem: meridiem)

        var comps = calendar.dateComponents([.year], from: now)
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    private static func parseAbsoluteTime(_ text: String, now: Date, calendar: Calendar) -> Date? {
        // Matches phrases like "resets at 3:00 PM", "resets at 3:00 AM",
        // "resets 2:20pm (UTC)", or "resets 3pm (UTC)"
        // — "at", the ":MM" minutes, and the IANA timezone suffix are all
        // optional (minutes default to :00 when omitted), and the meridiem
        // may be lowercase.
        let pattern = #"(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(AM|PM)(?:\s*\(([A-Za-z_]+(?:/[A-Za-z_]+)+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text),
              let meridiemRange = Range(match.range(at: 3), in: text),
              var hour = Int(text[hourRange])
        else { return nil }

        let minute: Int
        if let minuteRange = Range(match.range(at: 2), in: text), let parsedMinute = Int(text[minuteRange]) {
            minute = parsedMinute
        } else {
            minute = 0
        }

        let meridiem = text[meridiemRange].uppercased()
        hour = hour24(from: hour, meridiem: meridiem)

        var effectiveCalendar = calendar
        if let timeZoneRange = Range(match.range(at: 4), in: text),
           let timeZone = TimeZone(identifier: String(text[timeZoneRange])) {
            effectiveCalendar.timeZone = timeZone
        }

        var comps = effectiveCalendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        // Don't roll a past time to tomorrow: a banner reporting "resets
        // HH:MM" describes a time that was in the future when generated. If
        // we read it after HH:MM has passed, the limit has already cleared —
        // returning that past time lets the caller treat it as "resume now"
        // rather than waiting ~24h for the same clock time again.
        return effectiveCalendar.date(from: comps)
    }

    private static func parseRelativeDuration(_ text: String, now: Date) -> Date? {
        // Matches phrases like "try again in 2 hours" or "in 45 minutes"
        let pattern = #"(?i)in\s+(\d+)\s+(hour|hours|minute|minutes)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Int(text[amountRange])
        else { return nil }

        let unit = text[unitRange].lowercased()
        let seconds: TimeInterval = unit.hasPrefix("hour") ? Double(amount) * 3600 : Double(amount) * 60
        return now.addingTimeInterval(seconds)
    }
}
