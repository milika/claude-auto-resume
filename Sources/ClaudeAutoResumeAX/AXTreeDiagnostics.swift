import CoreGraphics

/// Produces a bounded, read-only textual summary of an accessibility tree —
/// used to diagnose why `ResumeActuator.resume(window:)` returned
/// `.inputNotFound` for a window the user can see has a chat input. Performs
/// no clicks or edits.
public enum AXTreeDiagnostics {
    public static func describe(root: AccessibilityElement) -> [String] {
        var lines: [String] = []
        lines.append("root role=\(d(root.role)) title=\(d(root.title)) frame=\(d(root.frame))")

        let textInputs = AXTreeWalker.findAll(in: root) { $0.role == "AXTextArea" || $0.role == "AXTextField" }
        lines.append("textInputs=\(textInputs.count)")
        for element in textInputs.prefix(5) {
            lines.append("  textInput role=\(d(element.role)) title=\(d(element.title)) value=\(d(element.value)) frame=\(d(element.frame))")
        }

        let buttons = AXTreeWalker.findAll(in: root) { $0.role == "AXButton" }
        lines.append("buttons=\(buttons.count)")
        for element in buttons.prefix(20) {
            lines.append("  button title=\(d(element.title)) frame=\(d(element.frame))")
        }

        let allElements = AXTreeWalker.findAll(in: root) { _ in true }
        var roleCounts: [String: Int] = [:]
        for element in allElements {
            roleCounts[element.role ?? "nil", default: 0] += 1
        }
        let histogram = roleCounts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        lines.append("totalElements=\(allElements.count) roles: \(histogram)")

        return lines
    }

    private static func d(_ text: String?) -> String {
        text ?? "nil"
    }

    private static func d(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return String(format: "(%.0f,%.0f,%.0f,%.0f)", frame.minX, frame.minY, frame.width, frame.height)
    }
}
