import AppKit
import ApplicationServices
import Foundation

// Test the embedded-newline hypothesis for ResumeActuator:
// does Claude Desktop's AXTextArea accept "continue\n" via
// kAXValueAttribute and treat it as a submit, or does it just
// show the literal newline in the input box?
//
// This standalone binary must have been granted Accessibility
// permission in System Settings for the AX calls to succeed.

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.anthropic.claudefordesktop"
}) else {
    print("ERROR: Claude Desktop not running")
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

print("Found \(axWindows.count) Claude window(s)")

// Find the AXTextArea inside the FIRST window (we just want to test
// the value-set behavior, not actually submit).
guard let firstWindow = axWindows.first else {
    print("ERROR: no Claude windows")
    exit(1)
}

// Find the text input via a depth-first walk
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

guard let input = findTextInput(in: firstWindow) else {
    print("ERROR: no AXTextArea found in first Claude window")
    exit(1)
}

print("Found AXTextArea in first Claude window.")
print()

// Read the value BEFORE we touch it
var beforeRef: CFTypeRef?
AXUIElementCopyAttributeValue(input, kAXValueAttribute as CFString, &beforeRef)
let beforeValue = (beforeRef as? String) ?? "(nil)"
print("Current value: \(beforeValue.prefix(80))")
print()

// Now write "continue\n" and see what happens
let testValue = "continue\n"
let writeResult = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, testValue as CFTypeRef)
print("Set value to 'continue\\n' (with embedded newline):")
print("  AX result: \(writeResult.rawValue)  (\(writeResult == .success ? "success" : "FAILURE"))")
print()

// Read it BACK to see what Claude actually shows
var afterRef: CFTypeRef?
AXUIElementCopyAttributeValue(input, kAXValueAttribute as CFString, &afterRef)
let afterValue = (afterRef as? String) ?? "(nil)"
print("Value after set (verbatim, repr-style):")
print("  \(String(reflecting: afterValue))")
print()

if afterValue == "continue\n" {
    print("RESULT: value retained the embedded newline verbatim (Claude treated it as text).")
    print("        Embedded-newline submit will NOT work — Claude will show 'continue' with a")
    print("        visible line break in the input, NOT submit the message.")
} else if afterValue == "continue" {
    print("RESULT: value came back as plain 'continue' — Claude may have submitted on the \\n.")
    print("        Watch the Claude window: did a new message get sent? If yes, this approach works.")
} else if afterValue.isEmpty {
    print("RESULT: value came back empty — Claude accepted and processed the value, the input is")
    print("        now clear (most likely a successful submit).")
} else {
    print("RESULT: value came back as something else: \(String(reflecting: afterValue.prefix(80)))")
    print("        Claude may have done partial processing.")
}

print()
print("Manual check needed: look at the Claude window. Did a 'continue' message get sent?")
print("(If yes, the embedded-newline approach in ResumeActuator will work. If no, we need")
print(" the Return keypress fallback instead.)")
