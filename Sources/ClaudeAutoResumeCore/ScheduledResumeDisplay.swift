import Foundation

/// Pure formatting helpers for showing scheduled resumes in the menu bar —
/// one line per `.scheduled` window, with a display name and a fire time.
public enum ScheduledResumeDisplay {
    public struct Entry: Equatable {
        public let windowID: String
        public let displayName: String
        public let fireAt: Date

        public init(windowID: String, displayName: String, fireAt: Date) {
            self.windowID = windowID
            self.displayName = displayName
            self.fireAt = fireAt
        }
    }

    /// Display name for a scheduled-resume menu row, derived from the
    /// window's live AX title — falls back to "Untitled window" when the
    /// title is `nil` (e.g. a brand-new conversation Claude Desktop hasn't
    /// generated a name for yet). `id` is now an opaque surrogate and can no
    /// longer be parsed for a label, so the title is the only source.
    public static func displayName(forTitle title: String?) -> String {
        title ?? "Untitled window"
    }

    /// Formats a single menu line, e.g. "tos player — resumes at 2:20 PM".
    public static func lineLabel(displayName: String, fireAt: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale.current
        return "\(displayName) — resumes at \(formatter.string(from: fireAt))"
    }
}
