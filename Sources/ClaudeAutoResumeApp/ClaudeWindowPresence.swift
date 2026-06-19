import AppKit
import CoreGraphics
import Foundation

/// Checks whether Claude's window is on-screen from the WindowServer's point
/// of view — independent of any `AXUIElement` handles we may be holding.
///
/// Why we need this: Claude's `kAXWindowsAttribute` can return a stale
/// reference whose geometry doesn't introspect (frame=nil, role=AXApplication
/// instead of AXWindow). When that happens, our `AXUIElement`-based
/// enumeration returns a useless handle and the actuator returns
/// `.inputNotFound` 6 times in a row. The 2026-06-18 22:10 activity log was
/// a textbook case.
///
/// `CGWindowListCopyWindowInfo` goes directly to the WindowServer, so it
/// reports what the user actually sees on screen — not what AX believes. If
/// Claude's window shows up there, we know the *window* exists even if our
/// AX handle is stale, and the actuator's stronger nudge (`transformProcessType`)
/// has a real process to promote. If Claude doesn't show up there either,
/// there's nothing to act on and the Watcher should bail out of the resume
/// instead of looping through 5 `.inputNotFound` retries.
public enum ClaudeWindowPresence {
    /// The bundle identifier we look for in `kCGWindowOwnerName`. Matches
    /// the bundle id in `Watcher.claudeBundleIdentifier`.
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// Returns the on-screen window bounds for the given pid, or `nil` if
    /// the process has no on-screen window. Filters out:
    /// - off-screen layers (`kCGWindowLayer != 0` — menu bar items, popups,
    ///   tooltips that are children of the app but aren't the main window)
    /// - zero-size windows (minimized or hidden)
    public static func onScreenBounds(forPID pid: pid_t) -> CGRect? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        for info in raw {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) == pid else { continue }
            // Skip non-main layers (menu bar items, popups, tooltips, etc.)
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            // Skip the app's "bounce" / launch window if it has no content yet.
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double,
                  w > 0, h > 0 else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Convenience: looks up Claude's pid and checks for an on-screen window.
    /// Returns the on-screen bounds if found, `nil` if Claude isn't running
    /// or has no on-screen window.
    public static func claudeOnScreenBounds() -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else { return nil }
        return onScreenBounds(forPID: app.processIdentifier)
    }
}
