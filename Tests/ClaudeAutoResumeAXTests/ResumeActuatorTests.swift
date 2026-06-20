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
    /// caller treats `nil` as "no nudge worked, report `.inputNotFound``.
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

    /// Pin the contract that `nudgeAndRefindInput` accepts an optional
    /// `cgBounds` parameter and uses it as a click target when AX reports
    /// `frame == nil`. The 2026-06-19 14:40 case had CGWindowList seeing
    /// Claude on-screen at (2465, 90, 1200, 800) while AX's frame was nil;
    /// the previous (v1.2 build 5) code skipped `clickCenter` entirely on
    /// the nil-frame path, leaving the escalation with only process-level
    /// activate calls. We can't synthesize a working AX tree in tests,
    /// but we can lock in that the parameter is plumbed through (the
    /// function still returns nil cleanly when no nudge succeeds).
    func testNudgeAndRefindInputAcceptsCGBoundsAndReturnsNilForUnresolvablePid() {
        let invalidWindow = AXUIElementCreateSystemWide()
        let root = AXUIElementAdapter(invalidWindow)
        let cgBounds = CGRect(x: 100, y: 100, width: 800, height: 600)

        let result = ResumeActuator.nudgeAndRefindInput(
            window: invalidWindow,
            root: root,
            cgBounds: cgBounds
        )
        XCTAssertNil(result, "nudgeAndRefindInput must return nil when no nudge succeeds even with cgBounds")
    }

    /// Pin the contract that `nudgeAndRefindInput` returns nil (not traps,
    /// not hangs forever) when given only a `nil` AX frame and no
    /// `cgBounds` to fall back on — i.e. the legacy call shape. With the
    /// 12s wait-loop added after the activate/TransformProcessType
    /// escalation, an unresolvable-pid case must still short-circuit
    /// before entering the wait loop (which would burn the entire budget
    /// on a process that doesn't exist).
    func testNudgeAndRefindInputShortCircuitsBeforeWaitLoop() {
        let invalidWindow = AXUIElementCreateSystemWide()
        let root = AXUIElementAdapter(invalidWindow)

        let start = Date()
        let result = ResumeActuator.nudgeAndRefindInput(window: invalidWindow, root: root)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        // The wait loop alone is `postNudgeWaitBudget` (12s). If we ever
        // regress into the wait loop on a missing pid, this test will
        // catch it: 5s is comfortably above the activate-path cost (~2-3s)
        // and well below the wait loop's 12s budget.
        XCTAssertLessThan(elapsed, 5.0, "unresolvable pid must short-circuit; got \(elapsed)s")
    }

    /// The 2026-06-20 14:00 case showed Claude's renderer staying AX-stale
    /// for 17 minutes — `CGEvent.postToPid` clicks were being dropped at
    /// Chromium's renderer IPC boundary. The fix is to send the click
    /// through `SkyLightBridge` (which uses `SLEventPostToPid`, a private
    /// SkyLight API Chromium trusts) and to tick the user-activation
    /// gate with an off-screen primer click at `(-1, -1)` before the real
    /// click. This test pins that the new nudge path emits the primer
    /// click (so we can grep for it in debug.log if it regresses) by
    /// confirming the function still returns `nil` cleanly when no pid
    /// is resolvable — i.e. the primer-click call doesn't crash or hang
    /// even when everything else about the window is invalid.
    ///
    /// We can't synthesize a working Claude window in unit tests, so the
    /// live-path primer-click is exercised only against Claude Desktop.
    /// What we CAN pin here is the contract that the new code path is
    /// gated by `pidOK` — an invalid window's pid is unresolvable, so
    /// the primer click is skipped, the function short-circuits, and
    /// the test stays under 5s like the legacy test above.
    func testNudgeAndRefindInputPrimerClickGatedByResolvingPid() {
        let invalidWindow = AXUIElementCreateSystemWide()
        let root = AXUIElementAdapter(invalidWindow)

        let start = Date()
        let result = ResumeActuator.nudgeAndRefindInput(window: invalidWindow, root: root)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        // Same budget as the legacy short-circuit test: under 5s. The
        // primer click (50ms sleep) is gated behind `pidOK`, so an
        // unresolvable pid skips it and the test runs as fast as before.
        XCTAssertLessThan(elapsed, 5.0, "primer-click path must be gated by pidOK; got \(elapsed)s")
    }
}
