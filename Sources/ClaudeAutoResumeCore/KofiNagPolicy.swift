import Foundation

/// Decides whether the Ko-fi support nag should be shown right now.
public enum KofiNagPolicy {
    /// How long to wait after first launch before the nag becomes eligible.
    public static let usageThreshold: TimeInterval = 5 * 24 * 3600

    public static func shouldShow(now: Date, firstLaunchDate: Date,
                                   lastShownDate: Date?, dismissedPermanently: Bool) -> Bool {
        guard !dismissedPermanently else { return false }
        guard now.timeIntervalSince(firstLaunchDate) >= usageThreshold else { return false }
        if let lastShownDate, Calendar.current.isDate(lastShownDate, inSameDayAs: now) {
            return false
        }
        return true
    }
}
