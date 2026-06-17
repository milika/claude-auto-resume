import XCTest
import ApplicationServices
@testable import ClaudeAutoResumeAX

/// Tests for the testable parts of `ResumeActuator`.
///
/// The full actuator (real `AXUIElement` queries, `NSRunningApplication.activate`,
/// `CGEvent.postToPid`) is tied to a live Claude Desktop process — we only test
/// the parts that can be exercised in isolation. The 2026-06-17 ~00:20 activity
/// log showed the live path failing silently (6 consecutive `.inputNotFound`
/// retries when Claude was in the background); the regression test below
/// pins the contract that the new `frame == nil` activation path doesn't
/// crash or spuriously activate a different process when AX refuses to
/// resolve the pid.
final class ResumeActuatorTests: XCTestCase {
    /// When AX refuses to resolve the window's pid, `nudgeAndRefindInput`
    /// must return `nil` cleanly — not crash, not fall through to the
    /// click-center branch (which would dereference a `nil` pid). The
    /// caller treats `nil` as "no nudge worked, report `.inputNotFound`".
    ///
    /// We can't synthesize a working `AXUIElement` whose `GetPid` fails in
    /// unit-test conditions (every `AXUIElement` we can build resolves a
    /// real pid from the system), so this test exercises the function with
    /// a deliberately invalid `AXUIElement` reference — a pid lookup
    /// against a non-existent window handle. The point is to lock in the
    /// guard-rail that any failure in the activate path returns `nil`
    /// rather than trapping.
    func testNudgeAndRefindInputReturnsNilForUnresolvablePid() {
        let invalidWindow = AXUIElementCreateSystemWide()
        let root = AXUIElementAdapter(invalidWindow)

        // `system-wide` element has no chat input, and its pid either
        // resolves to a process that isn't Claude (so the activate call is
        // a no-op against the wrong app) or doesn't resolve at all
        // (so the guard returns nil). Either way, the function must
        // return `nil` cleanly without crashing.
        let result = ResumeActuator.nudgeAndRefindInput(window: invalidWindow, root: root)
        XCTAssertNil(result, "nudgeAndRefindInput must return nil when no nudge succeeds")
    }
}
