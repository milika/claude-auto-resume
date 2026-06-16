import XCTest
@testable import ClaudeAutoResumeCore

final class WindowIdentityTrackerTests: XCTestCase {
    private struct FakeElement {
        let tag: Int
        var label: String
    }

    private func makeCounter() -> () -> String {
        var next = 0
        return {
            defer { next += 1 }
            return "id-\(next)"
        }
    }

    func testElementKeepsIDAcrossPositionChange() {
        let tracker = WindowIdentityTracker<FakeElement>(isSame: { $0.tag == $1.tag }, makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "A")
        let b = FakeElement(tag: 2, label: "B")

        let first = tracker.match([a, b])
        let second = tracker.match([b, a])

        XCTAssertEqual(first.first(where: { $0.element.tag == 1 })?.id,
                       second.first(where: { $0.element.tag == 1 })?.id)
        XCTAssertEqual(first.first(where: { $0.element.tag == 2 })?.id,
                       second.first(where: { $0.element.tag == 2 })?.id)
    }

    func testElementKeepsIDWhenUnrelatedPropertyChanges() {
        let tracker = WindowIdentityTracker<FakeElement>(isSame: { $0.tag == $1.tag }, makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "Old Title")

        let first = tracker.match([a])
        let renamed = FakeElement(tag: 1, label: "New Title")
        let second = tracker.match([renamed])

        XCTAssertEqual(first[0].id, second[0].id)
    }

    func testNewElementGetsFreshlyMintedID() {
        let tracker = WindowIdentityTracker<FakeElement>(isSame: { $0.tag == $1.tag }, makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "A")
        let b = FakeElement(tag: 2, label: "B")

        let first = tracker.match([a])
        let second = tracker.match([a, b])

        let bEntry = second.first(where: { $0.element.tag == 2 })
        XCTAssertNotEqual(bEntry?.id, first[0].id)
    }

    func testDisappearedElementIDIsNeverReused() {
        let tracker = WindowIdentityTracker<FakeElement>(isSame: { $0.tag == $1.tag }, makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "A")
        let similar = FakeElement(tag: 2, label: "A")

        let first = tracker.match([a])
        _ = tracker.match([])
        let third = tracker.match([similar])

        XCTAssertNotEqual(first[0].id, third[0].id)
    }

    // MARK: - Fallback key

    /// Reproduces the real-world failure: Claude Desktop's AX tree mutates
    /// when "View details" is pressed, and the window's `AXUIElement`
    /// (the `isSame`/`tag` signal) no longer matches on the very next poll —
    /// even though it's the same physical window. Without a fallback, this
    /// mints a fresh id, the old id is reported as "closed", and any
    /// in-flight scheduled-resume state keyed on the old id is lost.
    /// `fallbackKey` (here, `label`, standing in for the window's frame)
    /// stays stable across this churn and lets the tracker recognize it's
    /// the same window.
    func testFallbackKeyPreservesIDWhenPrimaryMatchFails() {
        let tracker = WindowIdentityTracker<FakeElement>(
            isSame: { $0.tag == $1.tag },
            fallbackKey: { AnyHashable($0.label) },
            makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "stable-frame")
        let first = tracker.match([a])

        // Same physical window, but its primary identity (`tag`, standing in
        // for the AXUIElement reference) has churned. `label` (fallback key,
        // standing in for the window's on-screen frame) is unchanged.
        let churned = FakeElement(tag: 2, label: "stable-frame")
        let second = tracker.match([churned])

        XCTAssertEqual(first[0].id, second[0].id)
    }

    func testFallbackKeyDoesNotMatchWhenKeysDiffer() {
        let tracker = WindowIdentityTracker<FakeElement>(
            isSame: { $0.tag == $1.tag },
            fallbackKey: { AnyHashable($0.label) },
            makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "frame-A")
        let first = tracker.match([a])

        // Both the primary signal AND the fallback key differ — this is a
        // genuinely different window, not a churned identity for `a`.
        let unrelated = FakeElement(tag: 2, label: "frame-B")
        let second = tracker.match([unrelated])

        XCTAssertNotEqual(first[0].id, second[0].id)
    }

    func testNilFallbackKeyFallsThroughToFreshID() {
        let tracker = WindowIdentityTracker<FakeElement>(
            isSame: { $0.tag == $1.tag },
            fallbackKey: { _ in nil },
            makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "A")
        let first = tracker.match([a])

        let churned = FakeElement(tag: 2, label: "A")
        let second = tracker.match([churned])

        // No fallback key available — behaves exactly as if no fallback were
        // configured: the churned element gets a fresh id.
        XCTAssertNotEqual(first[0].id, second[0].id)
    }

    func testFallbackKeyDoesNotStealIDFromExactMatch() {
        let tracker = WindowIdentityTracker<FakeElement>(
            isSame: { $0.tag == $1.tag },
            fallbackKey: { AnyHashable($0.label) },
            makeID: makeCounter())
        let a = FakeElement(tag: 1, label: "shared-frame")
        let b = FakeElement(tag: 2, label: "shared-frame")
        let first: [(id: String, element: FakeElement)] = tracker.match([a, b])

        // Both elements are unchanged — exact `isSame` matches must win even
        // though both share the same fallback key.
        let second: [(id: String, element: FakeElement)] = tracker.match([a, b])

        let firstIDForTagOne: String? = first.first(where: { $0.element.tag == 1 })?.id
        let secondIDForTagOne: String? = second.first(where: { $0.element.tag == 1 })?.id
        let firstIDForTagTwo: String? = first.first(where: { $0.element.tag == 2 })?.id
        let secondIDForTagTwo: String? = second.first(where: { $0.element.tag == 2 })?.id

        XCTAssertEqual(firstIDForTagOne, secondIDForTagOne)
        XCTAssertEqual(firstIDForTagTwo, secondIDForTagTwo)
    }
}
