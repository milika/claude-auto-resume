import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Mimics the new ResumeActuator path:
//   1. Raise window
//   2. Find AXTextArea
//   3. Set value to "continue" via kAXValueAttribute
//   4. Focus the *window* (not just the input)
//   5. Focus the text input
//   6. Post a Return keypress to Claude's PID
//   7. Read the input value back to verify submit

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
guard let targetWindow = axWindows.first else {
    print("ERROR: no windows")
    exit(1)
}

print("Using first window: \(targetWindow)")

// Raise
let raiseResult = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
print("Raise: \(raiseResult == .success ? "ok" : "FAILED")")

// Find AXTextArea via depth-first walk
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

guard let input = findTextInput(in: targetWindow) else {
    print("ERROR: no AXTextArea found")
    exit(1)
}
print("Found AXTextArea")

// === step 3: set value to "continue" ===
let setResult = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "continue" as CFTypeRef)
print("Set value to 'continue': \(setResult == .success ? "ok" : "FAILED")")

// Confirm value (in case renderer ignored)
var afterSet: CFTypeRef?
AXUIElementCopyAttributeValue(input, kAXValueAttribute as CFString, &afterSet)
print("  Value after set: \(String(reflecting: (afterSet as? String) ?? "nil"))")

// === step 4: focus the WINDOW (new behavior — not just the input) ===
let winFocusResult = AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
print("Window focus: \(winFocusResult == .success ? "ok" : "FAILED")")

// === step 5: focus the text input ===
let inputFocusResult = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
print("Input focus: \(inputFocusResult == .success ? "ok" : "FAILED")")

// === step 6: post Return keypress to Claude's PID ===
var pid: pid_t = 0
guard AXUIElementGetPid(targetWindow, &pid) == .success else {
    print("ERROR: failed to get PID")
    exit(1)
}
print("Claude PID: \(pid)")

let source = CGEventSource(stateID: .hidSystemState)
let returnKey: CGKeyCode = 0x24
guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
    print("ERROR: failed to create CGEvent")
    exit(1)
}
keyDown.postToPid(pid)
keyUp.postToPid(pid)
print("Posted Return keypress to PID \(pid)")

// === step 7: wait briefly then verify ===
print()
print("Waiting 800ms for Claude to process the keypress…")
Thread.sleep(forTimeInterval: 0.8)

var afterSubmit: CFTypeRef?
AXUIElementCopyAttributeValue(input, kAXValueAttribute as CFString, &afterSubmit)
let afterValue = (afterSubmit as? String) ?? "(nil)"
print("Value 800ms after submit: \(String(reflecting: afterValue))")
print()

if afterValue.isEmpty {
    print("RESULT: input cleared — looks like the submit went through.")
    print("        Check the Claude window: a 'continue' message should have been sent.")
} else if afterValue == "continue" {
    print("RESULT: input still shows 'continue' — the Return keypress was DROPPED.")
    print("        The set-value step worked but the submit did not take.")
    print("        This is the symptom the user reported earlier.")
} else {
    print("RESULT: input shows something else: \(String(reflecting: afterValue.prefix(80)))")
    print("        Claude may have processed partially.")
}
