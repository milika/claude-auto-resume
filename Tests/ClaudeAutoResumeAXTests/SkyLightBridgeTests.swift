import XCTest
@testable import ClaudeAutoResumeAX

/// Tests for the private-SPI bridge to SkyLight.framework. The dlopen +
/// dlsym path is exercised once at first use (lazily), so by the time any
/// test method runs, `isTrustedClickAvailable` reflects the real symbol
/// resolution on this machine. The cua-driver team confirmed these symbols
/// are present on macOS 14+; we verified `SLEventPostToPid` resolves on
/// macOS 26.5 here with `Scripts/probe-skylight.swift`.
final class SkyLightBridgeTests: XCTestCase {
    /// Pin the contract that `isTrustedClickAvailable` is true on this
    /// machine. If a future macOS removes `SLEventPostToPid` from
    /// SkyLight.framework, this test fails and we know immediately that
    /// Chromium-trusted clicks have silently degraded to the
    /// `CGEvent.postToPid` fallback. The diagnostic is the
    /// `[nudge] trustedClick=…` line in debug.log — operators should look
    /// there first if resumes start failing again.
    func testTrustedClickIsAvailableOnThisMachine() {
        // Resolve the lazy symbol at least once before checking. Without
        // this, `isTrustedClickAvailable` could be false on first access
        // (cold dlopen cache) and true later — better to fail loud and
        // early in a test environment than in production.
        _ = SkyLightBridge.isTrustedClickAvailable
        XCTAssertTrue(
            SkyLightBridge.isTrustedClickAvailable,
            "SLEventPostToPid did not resolve in SkyLight.framework on this machine — Chromium-trusted clicks unavailable, will silently fall back to public CGEvent.postToPid"
        )
    }

    /// `click(at:toPid:)` must not crash on a bogus pid. The function is
    /// fire-and-forget; a bad pid is logged at the SkyLight layer and
    /// silently dropped. The actuator calls this from a best-effort nudge
    /// path, so any throw or assertion here would break the resume flow
    /// even when the click is irrelevant.
    func testClickAtToBogusPidDoesNotCrash() {
        // A pid of 0 is not associated with any real process; SkyLight
        // (and the CGEvent fallback) both treat it as a no-op.
        SkyLightBridge.click(at: CGPoint(x: 100, y: 100), toPid: 0)
    }

    /// `postTrustedMouseEvent` to a bogus pid must not crash. Same
    /// reasoning as `click(at:toPid:)` — best-effort nudge path, no
    /// throwing.
    func testPostTrustedMouseEventToBogusPidDoesNotCrash() {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 50, y: 50),
            mouseButton: .left
        )
        XCTAssertNotNil(event)
        if let event {
            SkyLightBridge.postTrustedMouseEvent(event, toPid: 0)
        }
    }

    /// Off-screen click target. The primer-click path posts a click at
    /// (-1, -1) to tick Chromium's user-activation gate; the off-screen
    /// coordinate is part of the contract (Chromium discards it because
    /// no element claims it). Verify the call doesn't crash even with
    /// this unusual coordinate.
    func testClickAtNegativeOneOneDoesNotCrash() {
        SkyLightBridge.click(at: CGPoint(x: -1, y: -1), toPid: 0)
    }
}
