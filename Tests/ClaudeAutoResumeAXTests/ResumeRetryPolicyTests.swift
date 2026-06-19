import XCTest
@testable import ClaudeAutoResumeAX

final class ResumeRetryPolicyTests: XCTestCase {
    func testSentOutcomeForFreshResetReturnsIdle() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .sent, wasStale: false, retryBackoff: 30), .idle)
    }

    func testSentOutcomeForStaleResetSuppresses() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .sent, wasStale: true, retryBackoff: 30), .suppress)
    }

    func testSendControlNotFoundRetriesAfterBackoff() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .sendControlNotFound, wasStale: false, retryBackoff: 30), .retry(after: 30))
    }

    func testInputNotFoundRetriesAfterBackoff() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .inputNotFound, wasStale: false, retryBackoff: 30), .retry(after: 30))
    }

    func testActionFailedRetriesAfterBackoff() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .actionFailed, wasStale: false, retryBackoff: 30), .retry(after: 30))
    }

    /// Stale reset + actuator couldn't send: the banner isn't going to clear
    /// on its own (Claude already passed the reset time, and "continue" never
    /// made it into the chat), and re-detecting on the next poll will fire
    /// the same already-past reset time again immediately. Going straight to
    /// .suppress here is the only thing that breaks the per-poll retry loop
    /// — without it, a stale banner that can't be sent into produced 30+
    /// consecutive .sendControlNotFound events ~8s apart in the activity log
    /// (the underlying root cause is the banner being detected repeatedly
    /// across window-id churn, which the per-poll .retry doesn't outpace).
    func testNonSentOutcomeForStaleResetSuppressesImmediately() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .sendControlNotFound, wasStale: true, retryBackoff: 30), .suppress)
        XCTAssertEqual(ResumeRetryPolicy.action(for: .inputNotFound, wasStale: true, retryBackoff: 30), .suppress)
        XCTAssertEqual(ResumeRetryPolicy.action(for: .actionFailed, wasStale: true, retryBackoff: 30), .suppress)
    }

    func testNonSentOutcomeBelowRetryCapStillRetries() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .inputNotFound, wasStale: false, retryBackoff: 30,
                                                 retryCount: ResumeRetryPolicy.maxRetries - 1), .retry(after: 30))
    }

    /// A window stuck returning `.inputNotFound` (e.g. an off-Space Claude
    /// Desktop window whose AX tree never exposes the chat input) would
    /// otherwise retry every `retryBackoff` seconds forever, as has been
    /// observed in real activity logs with ~100 consecutive retries over
    /// ~50 minutes. Once `retryCount` reaches `maxRetries`, give up instead
    /// of retrying again.
    func testNonSentOutcomeAtRetryCapGivesUp() {
        XCTAssertEqual(ResumeRetryPolicy.action(for: .inputNotFound, wasStale: false, retryBackoff: 30,
                                                 retryCount: ResumeRetryPolicy.maxRetries), .giveUp)
        XCTAssertEqual(ResumeRetryPolicy.action(for: .sendControlNotFound, wasStale: false, retryBackoff: 30,
                                                 retryCount: ResumeRetryPolicy.maxRetries), .giveUp)
        XCTAssertEqual(ResumeRetryPolicy.action(for: .actionFailed, wasStale: false, retryBackoff: 30,
                                                 retryCount: ResumeRetryPolicy.maxRetries), .giveUp)
    }

    // MARK: - Stale-handle retry policy (2026-06-19 14:40 case)

    /// When AX returns a stale handle (CGWindowList sees Claude on-screen
    /// but AX's frame is nil or role=AXApplication), `.inputNotFound`
    /// usually means Claude's Chromium renderer is still repopulating the
    /// chat panel — that takes many seconds, often well over the 30s
    /// default backoff. Widen the budget so a window in that state gets
    /// `staleHandleMaxRetries` retries on `staleHandleRetryBackoff` (45s)
    /// before giving up. At 45s × 12 retries, that's ~12 minutes of
    /// recovery room.
    func testStaleHandleInputNotFoundRetriesOnLongerBackoff() {
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .inputNotFound, wasStale: false, retryBackoff: 30, staleHandle: true),
            .retry(after: ResumeRetryPolicy.staleHandleRetryBackoff)
        )
    }

    /// `.sendControlNotFound` and `.actionFailed` are NOT renderer-recovery
    /// signals — they mean the input was found but couldn't be driven, so
    /// the tight default budget is the right call. The stale-handle widening
    /// must apply only to `.inputNotFound`.
    func testStaleHandleOnlyWidensBudgetForInputNotFound() {
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .sendControlNotFound, wasStale: false, retryBackoff: 30, staleHandle: true),
            .retry(after: 30)
        )
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .actionFailed, wasStale: false, retryBackoff: 30, staleHandle: true),
            .retry(after: 30)
        )
    }

    /// Even with the wider budget, a window that's been retrying for
    /// `staleHandleMaxRetries` consecutive rounds still gives up. This
    /// bounds the worst case (Claude genuinely broken, not just busy) at
    /// ~12 minutes of retries before transitioning to `.suppressed`.
    func testStaleHandleGivesUpAtStaleHandleRetryCap() {
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .inputNotFound, wasStale: false, retryBackoff: 30,
                                     retryCount: ResumeRetryPolicy.staleHandleMaxRetries,
                                     staleHandle: true),
            .giveUp
        )
    }

    /// Below the cap, stale-handle `.inputNotFound` keeps retrying on the
    /// longer backoff. Locks in that a stale handle buys extra recovery
    /// time, not just at the cap.
    func testStaleHandleStillRetriesBelowCap() {
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .inputNotFound, wasStale: false, retryBackoff: 30,
                                     retryCount: ResumeRetryPolicy.staleHandleMaxRetries - 1,
                                     staleHandle: true),
            .retry(after: ResumeRetryPolicy.staleHandleRetryBackoff)
        )
    }

    /// A stale handle doesn't change anything about a stale reset — if
    /// the reset time was already in the past, we still go straight to
    /// `.suppress` instead of looping the stale-handle retry budget.
    /// `.sent + wasStale` still suppresses (we sent but Claude may not
    /// have actually picked it up — better to stop than spam "continue").
    func testStaleHandleDoesNotOverrideStaleResetSemantics() {
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .inputNotFound, wasStale: true, retryBackoff: 30, staleHandle: true),
            .suppress
        )
        XCTAssertEqual(
            ResumeRetryPolicy.action(for: .sent, wasStale: true, retryBackoff: 30, staleHandle: true),
            .suppress
        )
    }
}
