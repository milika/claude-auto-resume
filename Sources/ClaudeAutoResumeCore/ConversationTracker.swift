import Foundation

/// Tracks each watched conversation's state independently, keyed by window ID.
/// Untracked windows are implicitly `.idle`.
public final class ConversationTracker {
    private var states: [String: ConversationState] = [:]
    private var lastUnrecognizedText: [String: String] = [:]
    /// Preserved `.scheduled` fire times for windows that disappeared,
    /// keyed by conversation title. Lets a later window with the same title
    /// (but a different, freshly-minted id) pick up where a churned-away
    /// id left off — see `retire`/`adoptOrphanedDeadline`.
    private var orphanedDeadlines: [String: Date] = [:]

    public init() {}

    public func state(for windowID: String) -> ConversationState {
        states[windowID] ?? .idle
    }

    public func transition(windowID: String, to newState: ConversationState) {
        states[windowID] = newState
    }

    public func remove(windowID: String) {
        states.removeValue(forKey: windowID)
        lastUnrecognizedText.removeValue(forKey: windowID)
    }

    public func allWindowIDs() -> [String] {
        Array(states.keys)
    }

    /// Whether an `.unrecognized(rawText:)` detection for `windowID` is new
    /// information worth logging. A stale AX element can report the exact
    /// same text on every poll forever; only the first occurrence and any
    /// subsequent change in text should be logged.
    public func shouldLogUnrecognized(windowID: String, rawText: String) -> Bool {
        guard lastUnrecognizedText[windowID] != rawText else { return false }
        lastUnrecognizedText[windowID] = rawText
        return true
    }

    /// Drops `windowID` from tracking (like `remove`), but first preserves
    /// its `.scheduled` fire time under `title` so a later window with the
    /// same title can pick it up via `adoptOrphanedDeadline`. No-op for the
    /// orphan if `windowID` has no `.scheduled` state or `title` is `nil`.
    public func retire(windowID: String, title: String?) {
        if let title, case .scheduled(let fireAt) = state(for: windowID) {
            orphanedDeadlines[title] = fireAt
        }
        remove(windowID: windowID)
    }

    /// If a previously-retired window left a preserved deadline under
    /// `title`, transitions `windowID` to `.scheduled(fireAt:)` with that
    /// deadline, consumes the orphan entry, and returns the fire date.
    /// Returns `nil` (and makes no change) if there's nothing to adopt.
    @discardableResult
    public func adoptOrphanedDeadline(windowID: String, title: String?) -> Date? {
        guard let title, let fireAt = orphanedDeadlines.removeValue(forKey: title) else { return nil }
        transition(windowID: windowID, to: .scheduled(fireAt: fireAt))
        return fireAt
    }
}
