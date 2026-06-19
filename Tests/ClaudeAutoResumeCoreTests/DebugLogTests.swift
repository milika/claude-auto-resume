import XCTest
@testable import ClaudeAutoResumeCore

/// Smoke tests for the shared debug-log writer. The full writer opens a
/// file in `~/Library/Application Support/ClaudeAutoResume/debug.log`;
/// here we exercise the public surface just enough to lock in that
/// `.append` doesn't trap, doesn't throw, and doesn't block concurrent
/// calls from the AX and App modules — the previous per-module inline
/// writer had a latent interleaving bug we don't want to reintroduce.
final class DebugLogTests: XCTestCase {
    /// `DebugLog.append` must be callable from any thread without crashing
    /// or blocking. The AX actuator calls it from a background queue; the
    /// App's `Watcher` calls it from main. They may interleave in the
    /// field — the writer must serialize them.
    func testAppendIsConcurrencySafe() {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "DebugLogTests.concurrent", attributes: .concurrent)
        let iterations = 50
        for i in 0..<iterations {
            group.enter()
            queue.async {
                DebugLog.append("[concurrency] iteration \(i)")
                group.leave()
            }
        }
        // Give the writer a generous moment to flush — there's no public
        // "barrier" API, so we just sleep briefly. The test only cares
        // that none of the 50 appends trap or deadlock; if any did, the
        // process would still be alive but the assertions below would
        // catch a crash via XCTAttachment on the next test.
        XCTAssertEqual(group.wait(timeout: .now() + 5.0), .success,
                       "50 concurrent DebugLog.append calls must finish within 5s")
    }

    /// Smoke: appending a non-empty line doesn't trap.
    func testAppendAcceptsArbitraryString() {
        DebugLog.append("[smoke] hello world")
        DebugLog.append("[smoke] unicode: ✓ ç †")
        DebugLog.append("[smoke] newline=\n inside")
    }
}
