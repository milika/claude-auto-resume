import XCTest
@testable import ClaudeAutoResumeAX

struct MockElement: AccessibilityElement {
    let role: String?
    let title: String?
    let value: String?
    let frame: CGRect?
    let children: [AccessibilityElement]

    init(role: String? = nil, title: String? = nil, value: String? = nil, frame: CGRect? = nil,
         children: [AccessibilityElement] = []) {
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.children = children
    }
}

final class AXTreeWalkerTests: XCTestCase {
    func testFindFirstReturnsFirstMatchInDepthFirstOrder() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "button", title: "Send")
            ]),
            MockElement(role: "button", title: "Cancel")
        ])

        let found = AXTreeWalker.findFirst(in: tree) { $0.role == "button" }

        XCTAssertEqual(found?.title, "Send")
    }

    func testFindFirstReturnsNilWhenNoMatch() {
        let tree = MockElement(role: "window", children: [MockElement(role: "group")])
        XCTAssertNil(AXTreeWalker.findFirst(in: tree) { $0.role == "button" })
    }

    func testFindAllCollectsEveryMatchInDepthFirstOrder() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text", value: "first"),
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "second")
            ]),
            MockElement(role: "text", value: "third")
        ])

        let found = AXTreeWalker.findAll(in: tree) { $0.role == "text" }

        XCTAssertEqual(found.compactMap { $0.value }, ["first", "second", "third"])
    }

    /// A pathologically deep or cyclic live accessibility tree must not crash
    /// the walker (stack overflow) or hang it (unbounded IPC). Build a chain
    /// far past any realistic chat UI's depth and confirm both functions
    /// return gracefully instead of finding the match buried at the bottom.
    func testWalkGivesUpPastMaximumDepthInsteadOfCrashingOrHanging() {
        var deepestFirst = MockElement(role: "target", value: "buried")
        for _ in 0..<500 {
            deepestFirst = MockElement(role: "wrapper", children: [deepestFirst])
        }

        XCTAssertNil(AXTreeWalker.findFirst(in: deepestFirst) { $0.role == "target" })
        XCTAssertTrue(AXTreeWalker.findAll(in: deepestFirst) { $0.role == "target" }.isEmpty)
    }
}
