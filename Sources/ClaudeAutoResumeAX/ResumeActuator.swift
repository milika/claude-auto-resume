import AppKit
import ApplicationServices
import CoreGraphics
import Carbon
import ClaudeAutoResumeCore

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

    /// Total time, in seconds, to keep polling the AX tree for a freshly
    /// rendered text input after every nudge has run. The 2026-06-19 14:40
    /// activity log showed Claude's renderer took the better part of a minute
    /// to repopulate its chat panel after the rate-limit countdown ended —
    /// a single post-nudge AX probe wasn't enough. We poll every
    /// `postNudgePollInterval` seconds up to this total, so the actuator
    /// either finds an input or times out cleanly with the same `.inputNotFound`
    /// outcome the caller already handles.
    private static let postNudgeWaitBudget: TimeInterval = 12.0
    private static let postNudgePollInterval: TimeInterval = 0.5

    /// Types `continue` into the window's message input and triggers send.
    /// `cgBounds` is the on-screen bounds reported by `CGWindowList` for
    /// the window's pid, if known — used as a click-target when AX itself
    /// reports `frame == nil` (see `nudgeAndRefindInput`). Pass `nil` if the
    /// caller didn't run that cross-check.
    public static func resume(window: AXUIElement, cgBounds: CGRect? = nil) -> Outcome {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        let root = AXUIElementAdapter(window)

        var inputAdapter = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter

        // A background/off-Space Electron window's AX tree can expose only its
        // window chrome, with no chat input, until the window becomes the
        // focused renderer. Two flavors of nudge, depending on what AX reports:
        //
        //   - frame != nil  → click the window center; this brings Claude to
        //                     the front and the AX tree repopulates.
        //   - frame == nil  → the window isn't even reporting geometry to AX.
        //                     That means Claude isn't frontmost at all
        //                     (background window, hidden behind another app,
        //                     screen-locked, off-Space). kAXRaiseAction on the
        //                     window alone doesn't help here for Electron apps
        //                     — we have to frontmost the whole application via
        //                     NSRunningApplication so macOS asks AX to
        //                     repopulate the tree. (Observed in the 2026-06-17
        //                     ~00:20 activity log: 6 consecutive .inputNotFound
        //                     retries, all with frame=nil and only menu-bar
        //                     elements in the tree, because Claude was in the
        //                     background.)
        if inputAdapter == nil {
            inputAdapter = nudgeAndRefindInput(window: window, root: root, cgBounds: cgBounds)
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

    /// Best-effort nudge to bring Claude to the front when its AX tree doesn't
    /// expose a chat input. Tries, in order:
    ///   1. Click the window center if AX reports a frame, otherwise click
    ///      the `cgBounds` center from `CGWindowList` (if provided).
    ///   2. `NSRunningApplication.activate` (polite, 1.0s settle).
    ///   3. `TransformProcessType(.foregroundApplication)` (the Carbon hammer
    ///      used internally when an app launches and needs to come to the
    ///      front — bypasses "don't steal focus" but works where step 2 was
    ///      refused).
    ///   4. Wait-loop polling the AX tree for up to `postNudgeWaitBudget`
    ///      seconds, in case the renderer needs more time to repopulate the
    ///      chat panel after the activation finally landed.
    /// Returns the (possibly newly discovered) input adapter, or `nil` if
    /// no nudge succeeded and the wait budget elapsed.
    ///
    /// Every step writes a line to `debug.log` so a future "the actuator
    /// gave up and I can't tell why" post-mortem has evidence. The 2026-06-19
    /// 14:40 case previously logged only "root role=AXApplication frame=nil"
    /// after the fact — there was no record of whether `activate` had returned
    /// `true` or whether `TransformProcessType` had succeeded, so we couldn't
    /// tell if the escalation was being refused or just not getting enough
    /// settle time.
    ///
    /// Exposed `internal` for unit testing of the failure paths — see
    /// `ResumeActuatorTests`.
    internal static func nudgeAndRefindInput(
        window: AXUIElement,
        root: AXUIElementAdapter,
        cgBounds: CGRect? = nil
    ) -> AXUIElementAdapter? {
        var pid: pid_t = 0
        let pidOK = AXUIElementGetPid(window, &pid) == .success
        ClaudeAutoResumeCore.DebugLog.append(
            "[nudge] start: pidOK=\(pidOK) pid=\(pid) axFrame=\(root.frame.map { "\($0)" } ?? "nil") cgBounds=\(cgBounds.map { "\($0)" } ?? "nil") initialTextInputs=\(countTextInputs(in: root))")

        // Step 1a: AX frame present — click that center.
        if let frame = root.frame {
            clickCenter(of: frame, window: window)
            ClaudeAutoResumeCore.DebugLog.append("[nudge] clicked AX-frame center \(frame.midX),\(frame.midY); waiting 1.0s")
            Thread.sleep(forTimeInterval: 1.0)
            if let found = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter {
                ClaudeAutoResumeCore.DebugLog.append("[nudge] AX-frame click succeeded; textInputs=\(countTextInputs(in: root))")
                return found
            }
            ClaudeAutoResumeCore.DebugLog.append("[nudge] AX-frame click did not surface a text input; postTextInputs=\(countTextInputs(in: root))")
        }

        // Step 1b: frame == nil but CGWindowList has on-screen bounds — click
        // the CGWindowList center instead. The 2026-06-19 14:40 case had
        // CGWindowList seeing Claude at (2465, 90, 1200, 800) while AX
        // reported frame=nil; the previous code skipped `clickCenter`
        // entirely on the nil-frame path and went straight to process-level
        // activate, which alone didn't wake the renderer.
        if let cgBounds {
            clickCenter(of: cgBounds, window: window)
            ClaudeAutoResumeCore.DebugLog.append("[nudge] clicked CGWindowList center \(cgBounds.midX),\(cgBounds.midY); waiting 1.0s")
            Thread.sleep(forTimeInterval: 1.0)
            if let found = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter {
                ClaudeAutoResumeCore.DebugLog.append("[nudge] CGWindowList-bounds click succeeded; textInputs=\(countTextInputs(in: root))")
                return found
            }
            ClaudeAutoResumeCore.DebugLog.append("[nudge] CGWindowList-bounds click did not surface a text input; postTextInputs=\(countTextInputs(in: root))")
        }

        guard pidOK, let app = NSRunningApplication(processIdentifier: pid) else {
            ClaudeAutoResumeCore.DebugLog.append("[nudge] no resolvable pid for window; giving up")
            return nil
        }

        // Step 2: polite activation.
        let activated = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        ClaudeAutoResumeCore.DebugLog.append("[nudge] NSRunningApplication.activate returned \(activated); isActive=\(app.isActive) isFinishedLaunching=\(app.isFinishedLaunching); waiting 1.0s")
        Thread.sleep(forTimeInterval: 1.0)
        if let found = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter {
            ClaudeAutoResumeCore.DebugLog.append("[nudge] activate alone surfaced a text input; textInputs=\(countTextInputs(in: root))")
            return found
        }

        // Step 3: force-elevate the process to foreground. This is the same
        // hammer macOS uses internally when an app launches and needs to come
        // to the front — it can succeed where NSRunningApplication.activate
        // was refused, at the cost of bypassing the user's "don't steal focus"
        // preference. For our use case (Claude behind another fullscreen app
        // during a rate-limit countdown) that's the right tradeoff.
        //
        // `GetProcessForPID` is deprecated as of macOS 10.9 and Swift marks
        // it unavailable, but the underlying C function still works. We
        // construct the `ProcessSerialNumber` directly: for any modern
        // launchd-spawned process (which Claude Desktop is), the high 32
        // bits of the PSN are 0 and the low 32 bits are the pid.
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(pid))
        let transformStatus = TransformProcessType(&psn,
                                                   ProcessApplicationTransformState(kProcessTransformToForegroundApplication))
        ClaudeAutoResumeCore.DebugLog.append("[nudge] TransformProcessType returned OSStatus=\(transformStatus); waiting 1.0s")
        Thread.sleep(forTimeInterval: 1.0)
        if let found = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter {
            ClaudeAutoResumeCore.DebugLog.append("[nudge] TransformProcessType alone surfaced a text input; textInputs=\(countTextInputs(in: root))")
            return found
        }

        // Step 4: wait-loop. The activation has either succeeded or been
        // refused by now; what we're waiting on is the renderer repopulating
        // the chat panel. Polling every 0.5s gives us up to
        // `postNudgeWaitBudget` seconds of observation before giving up.
        let deadline = Date().addingTimeInterval(postNudgeWaitBudget)
        var polls = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: postNudgePollInterval)
            polls += 1
            if let found = AXTreeWalker.findFirst(in: root, where: { isTextInput($0) }) as? AXUIElementAdapter {
                ClaudeAutoResumeCore.DebugLog.append("[nudge] wait-loop found a text input after \(polls) polls (\(Double(polls) * postNudgePollInterval)s)")
                return found
            }
        }
        ClaudeAutoResumeCore.DebugLog.append("[nudge] wait-loop exhausted (\(polls) polls, ~\(Double(polls) * postNudgePollInterval)s); finalTextInputs=\(countTextInputs(in: root)) rootRole=\(root.role ?? "nil") rootFrame=\(root.frame.map { "\($0)" } ?? "nil")")
        return nil
    }

    /// Counts AXTextArea / AXTextField descendants in the tree rooted at
    /// `root`. Cheap enough to call at every nudge step (one DFS, no
    /// attribute queries beyond role).
    private static func countTextInputs(in root: AXUIElementAdapter) -> Int {
        AXTreeWalker.findAll(in: root, where: isTextInput).count
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
