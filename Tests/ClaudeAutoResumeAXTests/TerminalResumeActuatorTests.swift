import XCTest
@testable import ClaudeAutoResumeAX

/// Tests for the pure helpers of `TerminalResumeActuator`. The actuator's
/// full behavior (post keystrokes, focus, AX queries) is verified live
/// against a running Terminal — we test the parts we can isolate here.
final class TerminalResumeActuatorTests: XCTestCase {
    /// Pure verification: a successful resume shows the buffer growing
    /// AND a Claude-Code processing marker (`✻` / `✢` / `⏺`) appearing
    /// after our `continue` line.
    func testVerifyAcceptedDetectsProcessingMarkerAfterContinue() {
        let before = """
        ❯ hi
          ⎿  You've hit your session limit · resets 2:10pm
        """
        let after = """
        ❯ hi
          ⎿  You've hit your session limit · resets 2:10pm
        ❯ continue
        ✻ Sautéed for 0s
        """
        XCTAssertTrue(TerminalResumeActuator.verifyAcceptedForTesting(before: before, after: after))
    }

    /// If the buffer grew but no processing marker appears, the
    /// keystrokes were posted but Claude hasn't acted on them yet.
    /// Return false — the caller can retry.
    func testVerifyAcceptedRejectsBufferGrowthWithoutMarker() {
        let before = """
        ❯ hi
          ⎿  You've hit your session limit · resets 2:10pm
        """
        let after = """
        ❯ hi
          ⎿  You've hit your session limit · resets 2:10pm
        ❯ continue
        ⎿  (some kind of error, no marker)
        """
        XCTAssertFalse(TerminalResumeActuator.verifyAcceptedForTesting(before: before, after: after))
    }

    /// If the buffer didn't grow at all, the keystrokes didn't reach
    /// the prompt. Return false.
    func testVerifyAcceptedRejectsUnchangedBuffer() {
        let before = "❯\n"
        let after = "❯\n"
        XCTAssertFalse(TerminalResumeActuator.verifyAcceptedForTesting(before: before, after: after))
    }

    /// The processing marker may appear earlier in the scrollback from a
    /// prior turn. The verify function should look for the marker *after*
    /// our `continue` line specifically — not just anywhere.
    func testVerifyAcceptedRequiresMarkerAfterContinueLine() {
        let before = """
        ✻ Sautéed for 0s
        ❯ hi
          ⎿  Some other text
        """
        // Marker is BEFORE our `continue` line, not after. Should reject.
        let after = """
        ✻ Sautéed for 0s
        ❯ hi
          ⎿  Some other text
        ❯ continue
        """
        XCTAssertFalse(TerminalResumeActuator.verifyAcceptedForTesting(before: before, after: after))
    }

    /// All three processing-marker variants should be accepted
    /// (Claude Code has rotated through these over its lifetime).
    func testVerifyAcceptedHandlesAllMarkerVariants() {
        for marker in ["✻", "✢", "⏺"] {
            let before = "❯\n"
            let after = "❯\n❯ continue\n\(marker) Working for 2s\n"
            XCTAssertTrue(
                TerminalResumeActuator.verifyAcceptedForTesting(before: before, after: after),
                "marker \(marker) should be recognized as Claude processing"
            )
        }
    }
}
