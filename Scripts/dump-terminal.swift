import AppKit
import ApplicationServices
import Foundation

// Dump the AX tree of the Terminal application. The Claude CLI runs inside
// a Terminal window — its UI is character-cell text rendered into the
// terminal emulator, so we need to inspect the terminal's AX tree (which
// exposes the visible text as accessibility text).

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.apple.Terminal"
}) else {
    print("ERROR: Terminal not running")
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

var windowsRef: CFTypeRef?
let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
guard status == .success, let axWindows = windowsRef as? [AXUIElement] else {
    print("ERROR: failed to read windows: \(status.rawValue)")
    exit(1)
}

print("Found \(axWindows.count) Terminal window(s)")

for (i, w) in axWindows.enumerated() {
    print("\n========= Window \(i + 1) =========")

    // Read the title to identify which is the Claude window
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
    let title = (titleRef as? String) ?? "(no title)"
    print("Title: \(title)")

    // List attributes of the window itself
    var namesRef: CFArray?
    if AXUIElementCopyAttributeNames(w, &namesRef) == .success, let names = namesRef as? [String] {
        print("Window-level attributes:")
        for name in names.sorted() {
            var value: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(w, name as CFString, &value)
            if r == .success {
                let v: String
                if let s = value as? String { v = "String(\(s.prefix(120)))" }
                else if let n = value as? NSNumber { v = "Number(\(n))" }
                else if CFGetTypeID(value) == AXUIElementGetTypeID() { v = "AXUIElement" }
                else { v = "<\(type(of: value!))>" }
                print("  \(name): \(v)")
            }
        }
    }

    // Find the AXTextArea / scroll area and dump its text
    func findTextInputs(in element: AXUIElement, depth: Int = 0) {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"

        if role == "AXTextArea" || role == "AXScrollArea" {
            let indent = String(repeating: "  ", count: depth)
            print("\(indent)ROLE=\(role)")

            // Read value if present
            var vRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &vRef) == .success,
               let v = vRef as? String {
                print("\(indent)  AXValue[\(v.count) chars]:")
                let indented = v.split(separator: "\n", omittingEmptySubsequences: false).map { "\(indent)    \($0)" }.joined(separator: "\n")
                print(indented)
            }

            // Try subrole and description
            for attr in ["AXSubrole", "AXDescription", "AXHelp", "AXRoleDescription"] {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
                   let s = ref as? String {
                    print("\(indent)  \(attr): \(s)")
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for c in children {
                findTextInputs(in: c, depth: depth + 1)
            }
        }
    }

    print("\nText-related elements:")
    findTextInputs(in: w)

    // Also try reading the value of the entire window
    var wvalRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(w, kAXValueAttribute as CFString, &wvalRef) == .success,
       let wval = wvalRef as? String {
        print("\nWindow AXValue[\(wval.count) chars]:")
        print(wval.prefix(2000))
    }
}
