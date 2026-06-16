import Foundation

/// The lifecycle of a single watched conversation window.
///
/// Conversations move through `idle -> rateLimited(resetAt) -> scheduled(fireAt)
/// -> resuming -> idle`, tracked independently per window ID.
public enum ConversationState: Equatable {
    case idle
    /// The rate limit was detected; `resetAt` is when Claude says it clears.
    case rateLimited(resetAt: Date)
    /// A resume has been scheduled; `fireAt` is the (possibly staggered) moment
    /// the Resume Actuator will run — not necessarily identical to `resetAt`.
    case scheduled(fireAt: Date)
    case resuming
    /// The user pressed "Stop" on a scheduled resume; `since` is when that
    /// happened. Parked here — not re-detected or re-scheduled — until either
    /// the rate-limit banner disappears from the window entirely or a capped
    /// duration elapses since `since`, at which point `Watcher` returns it to
    /// `.idle` for normal detection. (An earlier "cancel but keep
    /// re-detecting" design immediately rescheduled a fresh resume whenever
    /// the window was still rate-limited, which made Stop look like a no-op.
    /// The time cap exists so a window can't stay suppressed forever if
    /// banner-clearing is never detected — e.g. due to AX flakiness.)
    case suppressed(since: Date)
}
