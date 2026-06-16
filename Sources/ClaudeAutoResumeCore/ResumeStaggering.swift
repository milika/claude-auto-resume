import Foundation

public enum ResumeStaggering {
    public struct FireTime: Equatable {
        public let windowID: String
        public let fireAt: Date

        public init(windowID: String, fireAt: Date) {
            self.windowID = windowID
            self.fireAt = fireAt
        }
    }

    /// Computes actual fire times for a set of reset-ready windows, ensuring
    /// consecutive fires (by original reset order) are at least `minimumGap`
    /// apart. Entries that are already far enough apart are left untouched.
    public static func staggeredFireTimes(
        for entries: [(windowID: String, resetAt: Date)],
        minimumGap: TimeInterval
    ) -> [FireTime] {
        let sorted = entries.sorted { $0.resetAt < $1.resetAt }

        var result: [FireTime] = []
        var previousFireAt: Date?

        for entry in sorted {
            let fireAt: Date
            if let previous = previousFireAt, entry.resetAt < previous.addingTimeInterval(minimumGap) {
                fireAt = previous.addingTimeInterval(minimumGap)
            } else {
                fireAt = entry.resetAt
            }
            result.append(FireTime(windowID: entry.windowID, fireAt: fireAt))
            previousFireAt = fireAt
        }

        return result
    }
}
