import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Mirrors TerminalResumeActuator.resume(window:) — the same path the app
// uses to send "continue" to Claude Code in Terminal.app. Use this to
// dry-run the keystroke injection without waiting for the scheduled
// 14:10 BG resume.
//
// Run with:    swift Scripts/test-terminal-resume.swift
//
// What it does:
//   1. Enumerate Terminal.app's windows
//   2. Find the one whose title contains "Claude Code" AND whose scrollback
//      contains "Claude Code v" (defensive fingerprint, same as the app)
//   3. Read the prompt's AXValue (full scrollback) BEFORE
//   4. Set focus on window + prompt (kAXFocusedAttribute)
//   5. Post "continue" character-by-character via CGEvent.postToPid
//   6. Post Return via CGEvent.postToPid
//   7. Read scrollback AFTER
//   8. Print a verdict: did the scrollback grow? Did "continue" appear?
//      Did a processing marker (✻/✢/⏺) appear?
//
// Note: Claude is currently rate-limited (resets 14:10 BG). If you run this
// before 14:10, Claude will receive "continue" and re-emit the rate-limit
// banner. The test still proves the keystroke injection works.

let terminalBundleID = "com.apple.Terminal"
let titleHint = "claude"
let scrollbackMarker = "Claude Code v"
let resumeText = "continue"
let returnKeyCode: CGKeyCode = 0x24
let perKeystrokeDelay: TimeInterval = 0.035
let verificationDelay: TimeInterval = 1.5

print("→ test-terminal-resume.swift  (\(Date()))")
print("  current time: \(Date())")
print()

// Step 1: enumerate Terminal.app
guard let terminalApp = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == terminalBundleID
}) else {
    print("ERROR: Terminal.app is not running")
    exit(1)
}
print("Terminal.app pid: \(terminalApp.processIdentifier)")

let appElement = AXUIElementCreateApplication(terminalApp.processIdentifier)
AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

var windowsRef: CFTypeRef?
let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
guard status == .success, let axWindows = windowsRef as? [AXUIElement] else {
    print("ERROR: failed to read Terminal windows: \(status.rawValue)")
    exit(1)
}
print("Terminal has \(axWindows.count) window(s)")
print()

// Step 2: find the Claude Code window
func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func findTextAreas(in element: AXUIElement, out: inout [AXUIElement]) {
    if let role = stringAttr(element, kAXRoleAttribute as String), role == "AXTextArea" {
        out.append(element)
    }
    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    if let children = childrenRef as? [AXUIElement] {
        for c in children { findTextAreas(in: c, out: &out) }
    }
}

func bestScrollback(in window: AXUIElement) -> String? {
    var tas: [AXUIElement] = []
    findTextAreas(in: window, out: &tas)
    var best: String?
    for ta in tas {
        if let v = stringAttr(ta, kAXValueAttribute as String), !v.isEmpty {
            if best == nil || v.count > best!.count { best = v }
        }
    }
    return best
}

func findPrompt(in window: AXUIElement) -> AXUIElement? {
    var tas: [AXUIElement] = []
    findTextAreas(in: window, out: &tas)
    // Prefer the one whose AXDescription is "shell" — that's Terminal's
    // identifier for the live prompt.
    for ta in tas {
        if let d = stringAttr(ta, kAXDescriptionAttribute as String), d == "shell" {
            return ta
        }
    }
    // Fall back: longest AXValue.
    var best: AXUIElement?
    var bestLen = 0
    for ta in tas {
        if let v = stringAttr(ta, kAXValueAttribute as String), v.count > bestLen {
            best = ta
            bestLen = v.count
        }
    }
    return best
}

var targetWindow: AXUIElement?
for w in axWindows {
    guard let title = stringAttr(w, kAXTitleAttribute as String) else { continue }
    guard title.lowercased().contains(titleHint) else { continue }
    guard let scrollback = bestScrollback(in: w) else { continue }
    guard scrollback.lowercased().contains(scrollbackMarker.lowercased()) else { continue }
    targetWindow = w
    print("Found target window: \"\(title)\"")
    break
}

guard let window = targetWindow else {
    print("ERROR: no Terminal window with 'Claude Code v' in scrollback.")
    print("       Open one before running this script.")
    exit(1)
}

guard let prompt = findPrompt(in: window) else {
    print("ERROR: no AXTextArea (prompt) in target window")
    exit(1)
}
print("Found prompt AXTextArea")
print()

// Step 3: scrollback BEFORE
let scrollbackBefore = bestScrollback(in: window) ?? ""
let beforeLines = scrollbackBefore.split(separator: "\n", omittingEmptySubsequences: false)
print("Scrollback BEFORE: \(beforeLines.count) lines, last 3:")
for line in beforeLines.suffix(3) {
    print("  │ \(line)")
}
print()

// Step 4: focus
_ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
_ = AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 0.15)

var pid: pid_t = 0
guard AXUIElementGetPid(window, &pid) == .success else {
    print("ERROR: failed to get Terminal PID")
    exit(1)
}
print("Terminal PID: \(pid)")
print()

// Step 5 + 6: post "continue" character by character, then Return
let source = CGEventSource(stateID: .hidSystemState)
print("Posting '\(resumeText)' + Return to PID \(pid) via CGEvent…")
for scalar in resumeText.unicodeScalars {
    let utf16 = Array(String(scalar).utf16)
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        print("ERROR: failed to create CGEvent for scalar \(scalar)")
        exit(1)
    }
    keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
    Thread.sleep(forTimeInterval: perKeystrokeDelay)
}
guard let retDown = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
      let retUp = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false) else {
    print("ERROR: failed to create Return CGEvent")
    exit(1)
}
retDown.postToPid(pid)
retUp.postToPid(pid)
print("Posted.")
print()

// Step 7: wait, read scrollback AFTER
print("Waiting \(Int(verificationDelay * 1000))ms for Claude to process…")
Thread.sleep(forTimeInterval: verificationDelay)

let scrollbackAfter = bestScrollback(in: window) ?? ""
let afterLines = scrollbackAfter.split(separator: "\n", omittingEmptySubsequences: false)
print("Scrollback AFTER: \(afterLines.count) lines, last 5:")
for line in afterLines.suffix(5) {
    print("  │ \(line)")
}
print()

// Step 8: verdict
let grew = afterLines.count > beforeLines.count
// Look back 20 lines — Claude Code's response can push our "continue" line
// well above the bottom 5 once it appends the rate-limit banner and the
// ✻ "Cooked for 0s" status line.
let recentTail = Array(afterLines.suffix(20))
let tailHasContinue = recentTail.contains { $0.localizedCaseInsensitiveContains("continue") }
let tailHasMarker = recentTail.contains { line in
    line.contains("✻") || line.contains("✢") || line.contains("⏺")
}
let scrollbackContainsRateLimit = scrollbackAfter.lowercased().contains("rate limit") ||
                                  scrollbackAfter.lowercased().contains("session limit")

print("→ verdict:")
if grew && tailHasContinue {
    print("  ✓ scrollback grew (\(beforeLines.count) → \(afterLines.count) lines)")
    print("  ✓ 'continue' line visible in tail")
    if tailHasMarker {
        print("  ✓ processing marker (✻/✢/⏺) present — Claude accepted the input")
    } else if scrollbackContainsRateLimit {
        print("  ⚠ rate-limit banner still present — Claude received input but is still limited")
        print("    (expected; resets at 14:10 BG)")
    } else {
        print("  ⚠ no processing marker, no rate-limit echo. Check the Terminal window")
        print("    manually to see what happened.")
    }
} else {
    print("  ✗ scrollback did not grow, or 'continue' line not visible. Keystroke may")
    print("    not have reached the prompt. Re-check Accessibility permission for the")
    print("    process running this script.")
}
print()

if scrollbackContainsRateLimit {
    print("  NOTE: the session resets at 14:10 BG. This test verifies the keystroke")
    print("        injection path; the actual resume will fire at 14:10 with whatever")
    print("        the scheduled-resume log shows.")
}
