import Foundation
import CoreGraphics
import Darwin

/// Bridge to private SkyLight.framework APIs that Chromium's renderer accepts
/// as **trusted** click sources. The public `CGEvent.postToPid(_:_:)` route
/// bypasses the HID stream (so the cursor doesn't warp), but Chromium drops
/// those events at the renderer IPC boundary because they lack the
/// HID-pipeline trust telemetry. `SLEventPostToPid` posts the same event
/// through WindowServer's auth-signed channel instead, and Chromium accepts
/// it. This is the unlock the cua-driver team reverse-engineered — see
/// https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md
/// for the long writeup.
///
/// The bridge resolves `SLEventPostToPid` at first use via `dlopen` +
/// `dlsym` against `/System/Library/PrivateFrameworks/SkyLight.framework`.
/// If the symbol is missing (older macOS, future macOS removes it), every
/// public method falls back to the equivalent `CGEvent.postToPid` call so
/// the actuator degrades gracefully instead of crashing.
///
/// Verified available on macOS 26.5 here: `SLEventPostToPid`,
/// `SLPSPostEventRecordTo`, `SLPSSetFrontProcessWithOptions`,
/// `SLEventCreateMouseEvent`. Verified NOT available:
/// `_AXObserverAddNotificationAndCheckRemote` (Cromium-Electron-AX-keepalive
/// SPI — was removed by the time we needed it, so we don't depend on it).
public enum SkyLightBridge {
    /// `SLEventPostToPid(pid_t, CGEventRef) -> void`. Same calling shape as
    /// `CGEvent.postToPid(_:_:)`, so callers can swap transparently.
    private typealias SLEventPostToPidFn = @convention(c) (pid_t, CGEvent) -> Void

    /// Lazily resolved function pointer. `nil` if the symbol is missing
    /// (older macOS or the framework was rejected by the OS sandbox). All
    /// callers fall back to `CGEvent.postToPid` when this is nil.
    private static let slEventPostToPid: SLEventPostToPidFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
            RTLD_LAZY
        ) else {
            return nil
        }
        // dlopen returns a handle we keep alive for the process lifetime.
        // We deliberately don't dlclose — the framework is used for every
        // resume attempt and the cost of repeated dlopen outweighs any
        // modest leak from holding one extra framework reference.
        guard let sym = dlsym(handle, "SLEventPostToPid") else {
            return nil
        }
        return unsafeBitCast(sym, to: SLEventPostToPidFn.self)
    }()

    /// True iff `SLEventPostToPid` resolved at startup. Exposed for tests
    /// and for the actuator's debug-log line so we can confirm in the wild
    /// whether the trusted path is in use.
    public static var isTrustedClickAvailable: Bool {
        slEventPostToPid != nil
    }

    /// Posts `event` to `pid` via the WindowServer-trusted channel, or
    /// falls back to `CGEvent.postToPid(_:_:)` if the symbol is missing.
    ///
    /// Why we fall back instead of erroring: the actuator runs unattended
    /// against future macOS releases. If Apple removes `SLEventPostToPid`,
    /// the worst case is "Chromium drops the click again," not a crash.
    public static func postTrustedMouseEvent(_ event: CGEvent, toPid pid: pid_t) {
        if let sl = slEventPostToPid {
            sl(pid, event)
        } else {
            event.postToPid(pid)
        }
    }

    /// Posts a pair of mouse-down / mouse-up events as a single click at
    /// `(x, y)` to `pid`. Uses the trusted SkyLight channel when available,
    /// otherwise `CGEvent.postToPid`.
    ///
    /// `mouseCursorPosition` on `CGEvent(mouseEventSource:…)` is a
    /// WindowServer-coordinate stamp that travels with the event. Setting
    /// it to the real target is what makes the synthetic click land at
    /// the right element (not at the cursor's actual on-screen position).
    public static func click(at point: CGPoint, toPid pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            return
        }
        postTrustedMouseEvent(mouseDown, toPid: pid)
        postTrustedMouseEvent(mouseUp, toPid: pid)
    }
}
