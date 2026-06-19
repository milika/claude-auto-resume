import Foundation

/// Decides what `Watcher` should do after a resume attempt completes.
public enum ResumeRetryPolicy {
    public enum Action: Equatable {
        /// The resume succeeded for a reset time that hadn't yet passed —
        /// return to `.idle` for normal detection.
        case idle
        /// The resume couldn't act (e.g. the UI hasn't caught up with the
        /// reported reset time yet). Retry directly after `after` seconds
        /// instead of waiting for the next poll to re-detect and reschedule
        /// — re-detection would compute the same already-past `resetAt` and
        /// fire again immediately, looping every poll interval.
        case retry(after: TimeInterval)
        /// The resume was sent, but it targeted a reset time already in the
        /// past. Sending "continue" didn't make that stale banner disappear,
        /// so re-detecting immediately would just resend "continue" forever.
        /// Suppress this window until the banner clears or the suppression
        /// cap elapses, same as a manual "Stop".
        case suppress
        /// The actuator has failed to act `maxRetries` times in a row for a
        /// reset time that hasn't passed (e.g. an off-Space window whose AX
        /// tree never exposes the chat input, returning `.inputNotFound`
        /// forever). Retrying indefinitely never sends "continue" — give up
        /// and suppress this window like a manual "Stop".
        case giveUp
    }

    /// Number of consecutive non-`.sent` outcomes (for a reset time that
    /// hasn't passed) before `.giveUp` is returned instead of `.retry`. At
    /// the default `retryBackoff` of 30s this is ~2.5 minutes — long enough
    /// to ride out transient AX hiccups, short enough to not loop for the
    /// ~50 minutes observed in the 2026-06-14 20:20 activity log.
    public static let maxRetries = 5

    /// Number of retries permitted when the AX handle was stale (CGWindowList
    /// saw Claude on-screen but AX returned `frame=nil` or `role=AXApplication`
    /// — typically Claude's Chromium renderer taking many seconds to repopulate
    /// the chat panel after a rate-limit countdown ends, as in the 2026-06-19
    /// 14:40 case). At the bumped `staleHandleRetryBackoff` of 45s this is
    /// ~12 minutes — long enough to outlast the observed 5–10 min renderer
    /// recovery window, short enough that an actually-broken Claude doesn't
    /// burn retries forever.
    public static let staleHandleMaxRetries = 12

    /// Backoff used when `staleHandle` is true. Longer than the default
    /// `retryBackoff` because renderer recovery is slow — the actuator's
    /// in-attempt wait-loop (`ResumeActuator.postNudgeWaitBudget`, 12s) plus
    /// this backoff gives Claude time to repopulate between attempts without
    /// spamming.
    public static let staleHandleRetryBackoff: TimeInterval = 45.0

    public static func action(for outcome: ResumeActuator.Outcome,
                              wasStale: Bool,
                              retryBackoff: TimeInterval,
                              retryCount: Int = 0,
                              staleHandle: Bool = false) -> Action {
        // Stale reset + actuator couldn't send: the banner isn't going to clear
        // on its own (Claude already passed the reset time, and "continue"
        // never made it into the chat), and re-detecting on the next poll will
        // re-fire immediately. Going straight to .suppress here is the only
        // thing that breaks the per-poll retry loop — see the activity log
        // showing 30+ consecutive .sendControlNotFound events ~8s apart when
        // this short-circuited to .retry instead.
        if outcome != .sent && wasStale { return .suppress }
        guard outcome == .sent else {
            // Stale AX handle: renderer recovery takes much longer than a
            // transient AX hiccup, so we permit many more retries on a
            // longer backoff before calling it a day. We only widen the
            // budget for `.inputNotFound` on a stale handle — that outcome
            // is what we get when Claude's AX tree genuinely has no chat
            // input. `.sendControlNotFound` / `.actionFailed` aren't
            // renderer-recovery signals (they mean the input exists but
            // can't be driven), so they keep the tighter budget.
            if staleHandle && outcome == .inputNotFound {
                return retryCount >= staleHandleMaxRetries
                    ? .giveUp
                    : .retry(after: max(retryBackoff, staleHandleRetryBackoff))
            }
            return retryCount >= maxRetries ? .giveUp : .retry(after: retryBackoff)
        }
        return wasStale ? .suppress : .idle
    }
}
