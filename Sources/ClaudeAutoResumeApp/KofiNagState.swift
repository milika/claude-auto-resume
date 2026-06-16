import Foundation

/// Persists state for the Ko-fi support nag (see `KofiNagPolicy`).
enum KofiNagState {
    static let kofiURL = URL(string: "https://ko-fi.com/milikadelic")!

    private static let firstLaunchKey = "KofiNag.firstLaunchDate"
    private static let lastShownKey = "KofiNag.lastShownDate"
    private static let dismissedKey = "KofiNag.dismissedPermanently"

    /// Records "now" as the first-launch date, but only the first time this
    /// is called — subsequent calls are no-ops.
    static func recordFirstLaunchIfNeeded(now: Date = Date()) {
        guard UserDefaults.standard.object(forKey: firstLaunchKey) == nil else { return }
        UserDefaults.standard.set(now, forKey: firstLaunchKey)
    }

    /// Falls back to "now" if `recordFirstLaunchIfNeeded` hasn't run yet —
    /// treats an unset date as "just installed" rather than crashing.
    static var firstLaunchDate: Date {
        UserDefaults.standard.object(forKey: firstLaunchKey) as? Date ?? Date()
    }

    static var lastShownDate: Date? {
        get { UserDefaults.standard.object(forKey: lastShownKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastShownKey) }
    }

    static var dismissedPermanently: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }
}
