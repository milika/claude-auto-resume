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
}
