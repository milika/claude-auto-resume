import XCTest
@testable import ClaudeAutoResumeCore

final class ConversationTrackerTests: XCTestCase {
    func testNewWindowStartsIdle() {
        let tracker = ConversationTracker()
        XCTAssertEqual(tracker.state(for: "win-1"), .idle)
    }

    func testTransitionUpdatesStateForThatWindowOnly() {
        let tracker = ConversationTracker()
        let resetAt = Date(timeIntervalSince1970: 5000)

        tracker.transition(windowID: "win-1", to: .rateLimited(resetAt: resetAt))

        XCTAssertEqual(tracker.state(for: "win-1"), .rateLimited(resetAt: resetAt))
        XCTAssertEqual(tracker.state(for: "win-2"), .idle, "win-2 must be unaffected by win-1's transition")
    }

    func testRemoveDropsTrackedState() {
        let tracker = ConversationTracker()
        tracker.transition(windowID: "win-1", to: .rateLimited(resetAt: Date()))

        tracker.remove(windowID: "win-1")

        XCTAssertEqual(tracker.state(for: "win-1"), .idle)
        XCTAssertFalse(tracker.allWindowIDs().contains("win-1"))
    }

    func testAllWindowIDsReflectsTrackedWindows() {
        let tracker = ConversationTracker()
        tracker.transition(windowID: "win-1", to: .rateLimited(resetAt: Date()))
        tracker.transition(windowID: "win-2", to: .scheduled(fireAt: Date()))

        XCTAssertEqual(Set(tracker.allWindowIDs()), Set(["win-1", "win-2"]))
    }

    // MARK: - shouldLogUnrecognized

    /// The first time a window reports `.unrecognized(rawText:)`, it's new
    /// information and must be logged.
    func testShouldLogUnrecognizedFirstTimeForWindow() {
        let tracker = ConversationTracker()
        XCTAssertTrue(tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests"))
    }

    /// A stale leftover banner element can report the exact same unrecognized
    /// text on every poll forever (e.g. every 8 seconds). Repeating that same
    /// text again is not new information and must not be logged again.
    func testShouldLogUnrecognizedReturnsFalseForRepeatedSameText() {
        let tracker = ConversationTracker()
        _ = tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests")

        XCTAssertFalse(tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests"))
    }

    /// If the unrecognized text changes (a different banner shape appears),
    /// that's new information and must be logged.
    func testShouldLogUnrecognizedReturnsTrueWhenTextChanges() {
        let tracker = ConversationTracker()
        _ = tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests")

        XCTAssertTrue(tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Usage limit reached"))
    }

    /// Different windows are tracked independently.
    func testShouldLogUnrecognizedTracksWindowsIndependently() {
        let tracker = ConversationTracker()
        _ = tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests")

        XCTAssertTrue(tracker.shouldLogUnrecognized(windowID: "win-2", rawText: "Server is temporarily limiting requests"))
    }

    /// Once a window closes and is removed, its last-seen unrecognized text
    /// is forgotten — if the same window id is reused, the same text is
    /// treated as new again.
    func testRemoveClearsLastUnrecognizedText() {
        let tracker = ConversationTracker()
        _ = tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests")

        tracker.remove(windowID: "win-1")

        XCTAssertTrue(tracker.shouldLogUnrecognized(windowID: "win-1", rawText: "Server is temporarily limiting requests"))
    }

    // MARK: - retire / adoptOrphanedDeadline

    /// A window with a pending `.scheduled` resume that disappears is removed
    /// from tracking (same as `remove`), but its deadline is preserved under
    /// its title for a later window to adopt.
    func testRetirePreservesScheduledDeadlineForTitle() {
        let tracker = ConversationTracker()
        let fireAt = Date(timeIntervalSince1970: 5000)
        tracker.transition(windowID: "win-1", to: .scheduled(fireAt: fireAt))

        tracker.retire(windowID: "win-1", title: "tos player")

        XCTAssertEqual(tracker.state(for: "win-1"), .idle)
        XCTAssertFalse(tracker.allWindowIDs().contains("win-1"))
    }

    /// A new window ID with the same title as a retired window inherits its
    /// preserved deadline, transitioning straight to `.scheduled`.
    func testAdoptOrphanedDeadlineRestoresScheduledStateForNewWindowID() {
        let tracker = ConversationTracker()
        let fireAt = Date(timeIntervalSince1970: 5000)
        tracker.transition(windowID: "win-1", to: .scheduled(fireAt: fireAt))
        tracker.retire(windowID: "win-1", title: "tos player")

        let adopted = tracker.adoptOrphanedDeadline(windowID: "win-2", title: "tos player")

        XCTAssertEqual(adopted, fireAt)
        XCTAssertEqual(tracker.state(for: "win-2"), .scheduled(fireAt: fireAt))
    }

    /// No orphaned deadline exists for a title that was never retired.
    func testAdoptOrphanedDeadlineReturnsNilWhenNoOrphanForTitle() {
        let tracker = ConversationTracker()

        XCTAssertNil(tracker.adoptOrphanedDeadline(windowID: "win-2", title: "tos player"))
        XCTAssertEqual(tracker.state(for: "win-2"), .idle)
    }

    /// An orphaned deadline is consumed by the first window that adopts it;
    /// a second window with the same title finds nothing left to adopt.
    func testAdoptOrphanedDeadlineConsumesItOnce() {
        let tracker = ConversationTracker()
        let fireAt = Date(timeIntervalSince1970: 5000)
        tracker.transition(windowID: "win-1", to: .scheduled(fireAt: fireAt))
        tracker.retire(windowID: "win-1", title: "tos player")

        _ = tracker.adoptOrphanedDeadline(windowID: "win-2", title: "tos player")
        let second = tracker.adoptOrphanedDeadline(windowID: "win-3", title: "tos player")

        XCTAssertNil(second)
    }

    /// Retiring a window that has no pending `.scheduled` resume (e.g. it was
    /// `.idle` or `.suppressed`) creates no orphan to adopt.
    func testRetireWithoutScheduledStateDoesNotCreateOrphan() {
        let tracker = ConversationTracker()
        tracker.transition(windowID: "win-1", to: .rateLimited(resetAt: Date()))

        tracker.retire(windowID: "win-1", title: "tos player")

        XCTAssertNil(tracker.adoptOrphanedDeadline(windowID: "win-2", title: "tos player"))
    }

    /// A window with no title (nil) can't be matched back up later, so
    /// retiring it creates no orphan.
    func testRetireWithNilTitleDoesNotCreateOrphan() {
        let tracker = ConversationTracker()
        let fireAt = Date(timeIntervalSince1970: 5000)
        tracker.transition(windowID: "win-1", to: .scheduled(fireAt: fireAt))

        tracker.retire(windowID: "win-1", title: nil)

        XCTAssertNil(tracker.adoptOrphanedDeadline(windowID: "win-2", title: "tos player"))
    }
}
