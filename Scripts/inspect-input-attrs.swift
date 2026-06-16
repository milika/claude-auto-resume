import AppKit
import ApplicationServices
import Foundation

// Inspect every attribute Claude's text input exposes, to figure out
// which one actually controls the typed text.

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.anthropic.claudefordesktop"
}) else {
    print("ERROR: Claude Desktop not running")
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

var windowsRef: CFTypeRef?
AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
guard let axWindows = windowsRef as? [AXUIElement] else { exit(1) }
guard let w = axWindows.first else { exit(1) }

func findTextInput(in element: AXUIElement) -> AXUIElement? {
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    if let role = roleRef as? String, role == "AXTextArea" || role == "AXTextField" {
        return element
    }
    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    if let children = childrenRef as? [AXUIElement] {
        for c in children {
            if let found = findTextInput(in: c) { return found }
        }
    }
    return nil
}

guard let input = findTextInput(in: w) else { print("no input"); exit(1) }

// List every attribute this element exposes
var namesRef: CFArray?
let namesResult = AXUIElementCopyAttributeNames(input, &namesRef)
guard namesResult == .success, let names = namesRef as? [String] else {
    print("CopyAttributeNames failed: \(namesResult.rawValue)")
    exit(1)
}

print("Attributes exposed by the AXTextArea:")
for name in names.sorted() {
    var value: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(input, name as CFString, &value)
    if r == .success {
        let v: String
        if let s = value as? String {
            v = "String(\(s.prefix(80)))"
        } else if let n = value as? NSNumber {
            v = "Number(\(n))"
        } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
            v = "AXUIElement"
        } else if let arr = value as? [Any] {
            v = "Array(count=\(arr.count))"
        } else if value == nil {
            v = "nil"
        } else {
            v = "<\(type(of: value!))>"
        }
        print("  \(name): \(v)")
    } else {
        print("  \(name): error(\(r.rawValue))")
    }
}

print()
print("Writable attributes:")
for name in names.sorted() {
    var isSettable: DarwinBoolean = false
    let r = AXUIElementIsAttributeSettable(input, name as CFString, &isSettable)
    if r == .success && isSettable.boolValue {
        print("  \(name)")
    }
}
