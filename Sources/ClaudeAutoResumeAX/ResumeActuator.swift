import ApplicationServices
import CoreGraphics

public enum ResumeActuator {
    public enum Outcome: Equatable {
        case sent
        case inputNotFound
        case sendControlNotFound
        case actionFailed
    }

    private static let resumeText = "continue"
    /// Carbon's `kVK_Return` — the virtual keycode for the Return key.
    private static let returnKeyCode: CGKeyCode = 0x24
    /// Delay between successive character keystrokes. Below ~20ms, Claude's
    /// Chromium renderer starts dropping characters; above ~50ms it visibly
    /// lags. 35ms is in the safe middle.
    private static let perKeystrokeDelay: TimeInterval = 0.035

    /// Types `continue` into the window's message input and triggers send.
    public static func resume(window: AXUIElement) -> Outcome {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        let root = AXUIElementAdapter(window)

        var inputAdapter = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter

        // A background/off-Space Electron window's AX tree can expose only its
        // window chrome, with no chat input, until the window becomes the
        // focused renderer. Clicking the center of its frame can bring it into
        // focus so the AX tree repopulates; retry the search once afterwards.
        if inputAdapter == nil, let frame = root.frame {
            clickCenter(of: frame, window: window)
            inputAdapter = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter
        }

        guard let inputAdapter else {
            return .inputNotFound
        }

        // Focus the *window* first, then the input — without window focus,
        // CGEvent.postToPid events are silently dropped when Claude isn't the
        // frontmost app.
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(inputAdapter.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Brief settle so the Chromium renderer's focus state catches up
        // before keystrokes start arriving.
        Thread.sleep(forTimeInterval: 0.15)

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            return .sendControlNotFound
        }

        // Claude Desktop's chat input is a Chromium content-editable div. It
        // listens to *real* keyboard events, NOT to `AXUIElementSetAttributeValue`
        // on `kAXValueAttribute` — the AX attribute write returns success but
        // the renderer's input state never updates, so a subsequent Return
        // posts to an empty input. The only reliable way to populate the input
        // is to post each character of the resume text as a real keystroke via
        // CGEvent + `keyboardSetUnicodeString`, then post Return.
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

        // Submit with a real Return keypress. The renderer's submit handler
        // fires on keyDown of the virtual-key Return, so posting both is fine.
        guard let retDown = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let retUp = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false) else {
            return .actionFailed
        }
        retDown.postToPid(pid)
        retUp.postToPid(pid)
        return .sent
    }

    /// Posts a left-click at the center of `frame` directly to `window`'s
    /// process — best-effort, ignores failures, since this is only a
    /// best-effort nudge before falling back to `.inputNotFound`.
    private static func clickCenter(of frame: CGRect, window: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        mouseDown.postToPid(pid)
        mouseUp.postToPid(pid)
    }

    private static func isTextInput(_ element: AccessibilityElement) -> Bool {
        element.role == "AXTextArea" || element.role == "AXTextField"
    }
}
