import XCTest
@testable import ClaudeAutoResumeAX

final class AXTreeDiagnosticsTests: XCTestCase {
    func testDescribeReportsTextInputCountAndDetails() {
        let tree = MockElement(role: "AXWindow", title: "Claude", children: [
            MockElement(role: "AXTextArea", title: "Message Claude", value: "")
        ])

        let lines = AXTreeDiagnostics.describe(root: tree)

        XCTAssertTrue(lines.contains("textInputs=1"))
        XCTAssertTrue(lines.contains { $0.contains("Message Claude") })
    }

    func testDescribeReportsZeroTextInputsAndRoleHistogramWhenNoneFound() {
        let tree = MockElement(role: "AXWindow", title: "Claude", children: [
            MockElement(role: "AXButton", title: "View details"),
            MockElement(role: "AXStaticText", value: "Server is temporarily limiting requests")
        ])

        let lines = AXTreeDiagnostics.describe(root: tree)

        XCTAssertTrue(lines.contains("textInputs=0"))
        XCTAssertTrue(lines.contains { $0.contains("buttons=1") })
        XCTAssertTrue(lines.contains { $0.contains("View details") })
        XCTAssertTrue(lines.contains { line in
            line.hasPrefix("totalElements=") && line.contains("AXButton=1") && line.contains("AXStaticText=1")
        })
    }

    func testDescribeIncludesRootFrameAndTitle() {
        let tree = MockElement(role: "AXWindow", title: "Claude", frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        let lines = AXTreeDiagnostics.describe(root: tree)

        XCTAssertTrue(lines[0].contains("Claude"))
        XCTAssertTrue(lines[0].contains("800"))
    }
}
