import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Milestone 2 of the Terminal support: resume Claude Code in a Terminal
/// window by typing `continue` into the prompt and pressing Return.
///
/// This is the Terminal analogue of `ResumeActuator` (which targets Claude
/// Desktop's Chromium-rendered input). The two paths are kept separate
/// because the surface shape and verification logic differ:
///
/// - Claude Desktop: raise the window, set the chat input value via real
///   Unicode keystrokes, press Send button or Return. Verification is
///   "the AX value attribute now contains 'continue' and the renderer has
///   processed the keystrokes".
///
/// - Claude Code in Terminal: focus the Terminal window, type `continue`
///   into the shell prompt, press Return. The shell submits the line,
///   Claude Code processes it, the prompt returns to empty. Verification
///   is "the scrollback has a new response block (or the rate-limit banner
///   is gone)".
public enum TerminalResumeActuator {
    public enum Outcome: Equatable {
        /// Keystrokes were posted; verification confirmed Claude processed
        /// the message.
        case sent
        /// Could not locate the prompt's `AXTextArea` in the window's tree.
        case inputNotFound
        /// Could not derive Terminal's PID.
        case sendControlNotFound
        /// The CGEvent creation or posting failed.
        case actionFailed
        /// The verification step did not detect a Claude response within
        /// the timeout window — the keystrokes may or may not have been
        /// accepted, but no positive confirmation.
        case unverified
    }

    private static let resumeText = "continue"
    /// Carbon's `kVK_Return` — the virtual keycode for the Return key.
    private static let returnKeyCode: CGKeyCode = 0x24
    /// Delay between successive character keystrokes. 35ms is in the safe
    /// middle for both Chromium (Desktop) and the Terminal emulator.
    private static let perKeystrokeDelay: TimeInterval = 0.035
    /// Time to wait after pressing Return before reading the scrollback to
    /// verify the resume. Claude Code's TUI is fast (~hundreds of ms) but
    /// if the user has a slow connection or a large model, 1.5s gives
    /// breathing room.
    private static let verificationDelay: TimeInterval = 1.5
    /// Marker substrings we look for in the new scrollback to confirm
    /// Claude Code processed the message. The Claude Code v2.1.x TUI
    /// shows a `✻` or `✢` glyph followed by a status line ("Sautéed for
    /// Xs", "Worked for Xs", etc.) right after the user's `❯` line is
    /// submitted. Any of these markers indicates Claude accepted the
    /// input — even if it immediately re-emits a rate-limit banner (which
    /// would mean the rate limit hasn't actually reset, in which case
    /// `ResumeRetryPolicy` handles the retry).
    private static let processedMarkers = [
        "✻",  // Claude Code's "thinking" glyph (v2.1.x)
        "✢",  // Older variant
        "⏺",  // Earlier variant
    ]

    /// Types `continue` into the Terminal window's prompt and verifies that
    /// Claude Code processed the message. Returns the outcome for the
    /// activity log and the resume-retry policy.
    public static func resume(window: AXUIElement) -> Outcome {
        let root = AXUIElementAdapter(window)

        // Find the prompt element. We want the `AXTextArea` whose
        // `AXDescription` is "shell" (Terminal's identifier for the live
        // shell prompt). If multiple matches, prefer the one whose
        // `AXValue` is the scrollback — that's the prompt element, the
        // live editable input. (For v1 this is the bottom-most `AXTextArea`
        // since the user has confirmed one session per Terminal window.)
        guard let prompt = findPrompt(in: root) else {
            return .inputNotFound
        }

        // Read the scrollback BEFORE we act — this is what we'll compare
        // against after the keystrokes to verify Claude accepted our
        // message. Reading the entire scrollback via `AXValue` is what
        // the prompt element exposes, and the string can be a few KB for
        // a long-running session.
        let scrollbackBefore = prompt.value ?? ""

        // Focus the Terminal *window* first, then the prompt. Without
        // window focus, `CGEvent.postToPid` events can be silently dropped
        // when Terminal isn't the frontmost app. We can't reliably
        // `kAXRaiseAction` Terminal (it's a multi-window app and the
        // semantics differ from Claude Desktop's) — `kAXFocusedAttribute`
        // is the portable way.
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(prompt.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Brief settle so the Terminal emulator's focus state catches up
        // before keystrokes start arriving.
        Thread.sleep(forTimeInterval: 0.15)

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            return .sendControlNotFound
        }

        // Type each character of "continue" as a real Unicode keystroke.
        // Same Chromium-vs-AX discovery as Claude Desktop: Terminal's
        // emulator listens to real keyboard events, not AX value writes.
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in resumeText.unicodeScalars {
            let utf16 = Array(String(scalar).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .actionFailed
            }
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            Thread.sleep(forTimeInterval: perKeystrokeDelay)
        }

        // Submit with a real Return keypress.
        guard let retDown = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let retUp = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false) else {
            return .actionFailed
        }
        retDown.postToPid(pid)
        retUp.postToPid(pid)

        // Wait briefly and verify. If the scrollback grew AND a
        // "processing" marker appeared, Claude accepted the message.
        Thread.sleep(forTimeInterval: verificationDelay)
        let scrollbackAfter = readScrollback(in: prompt) ?? ""
        if verifyAccepted(before: scrollbackBefore, after: scrollbackAfter) {
            return .sent
        }
        return .unverified
    }

    /// Find the prompt `AXTextArea` in a Terminal window. Returns nil if
    /// the layout doesn't match expectations (e.g. the user is on an
    /// iTerm2 / Warp variant — those are documented as future work in
    /// `docs/terminal-cli-support.md`).
    ///
    /// In Terminal.app, there's exactly one `AXTextArea` per window, and
    /// it serves double-duty: the entire scrollback is exposed via its
    /// `AXValue` and the user's live prompt input is the same element with
    /// the cursor positioned at the bottom. We just find that one element.
    private static func findPrompt(in root: AccessibilityElement) -> AXUIElementAdapter? {
        let candidates = AXTreeWalker.findAll(in: root) { $0.role == "AXTextArea" }
        // Prefer the one whose `AXDescription` is "shell" — that's
        // Terminal's identifier for the live prompt. If multiple match
        // (e.g. iTerm2 has separate prompt + scrollback), pick the
        // one that exposes a value (the scrollback; the prompt is
        // typically the same element in Terminal.app).
        let shell = candidates.first { element in
            guard let adapter = element as? AXUIElementAdapter else { return false }
            return description(of: adapter) == "shell"
        }
        if let shell = shell as? AXUIElementAdapter { return shell }

        // Fall back: pick the AXTextArea with the longest value.
        let withValue = candidates.compactMap { ta -> (AccessibilityElement, Int)? in
            guard let v = ta.value, !v.isEmpty else { return nil }
            return (ta, v.count)
        }
        let best = withValue.max(by: { $0.1 < $1.1 })?.0
        return best as? AXUIElementAdapter
    }

    private static func description(of adapter: AXUIElementAdapter) -> String? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(adapter.element, kAXDescriptionAttribute as CFString, &ref)
        guard r == .success, let desc = ref as? String else { return nil }
        return desc
    }

    /// Re-read the scrollback after the keystrokes. The prompt element's
    /// `AXValue` is the full scrollback string in Terminal.app.
    private static func readScrollback(in prompt: AXUIElementAdapter) -> String? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(prompt.element, kAXValueAttribute as CFString, &ref)
        guard r == .success, let v = ref as? String else { return nil }
        return v
    }

    /// True if the post-keystroke scrollback looks like Claude Code
    /// accepted our message: the buffer grew, and a "processing" marker
    /// (✻ / ✢ / ⏺) appears after our `❯ continue` line.
    private static func verifyAccepted(before: String, after: String) -> Bool {
        verifyAcceptedForTesting(before: before, after: after)
    }

    /// Public-for-testing mirror of `verifyAccepted` so unit tests can
    /// exercise the pure verification logic without needing a live
    /// Terminal to drive the surrounding CGEvent / focus side effects.
    public static func verifyAcceptedForTesting(before: String, after: String) -> Bool {
        guard after.count > before.count else { return false }
        // Find our `continue` line in the after-buffer; the marker should
        // appear in the lines that come after it.
        guard let range = after.range(of: resumeText) else { return false }
        let tail = after[range.upperBound...]
        return processedMarkers.contains { tail.contains($0) }
    }
}

extension TerminalResumeActuator.Outcome {
    /// Map to the shared `ResumeActuator.Outcome` so the existing
    /// `ResumeRetryPolicy` can be applied uniformly. The terminal
    /// actuator's `.unverified` is a strictly weaker form of `.sent`
    /// (keystrokes were posted but the post-action verification step
    /// didn't see Claude accept them) — for the retry policy, treat it
    /// like an `.actionFailed` (retry with backoff) so we don't bail out
    /// on a single missed verification.
    public func toResumeOutcome() -> ResumeActuator.Outcome {
        switch self {
        case .sent: return .sent
        case .inputNotFound: return .inputNotFound
        case .sendControlNotFound: return .sendControlNotFound
        case .actionFailed: return .actionFailed
        case .unverified: return .actionFailed
        }
    }
}
