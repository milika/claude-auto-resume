import AppKit
import ApplicationServices

public struct TrackedWindow {
    public let id: String
    /// The window's current AX title, re-read fresh on every poll — not
    /// frozen at first detection. `nil` when the window has no title yet
    /// (e.g. "New conversation" before Claude Desktop names it).
    public let title: String?
    public let element: AccessibilityElement

    public init(id: String, title: String?, element: AccessibilityElement) {
        self.id = id
        self.title = title
        self.element = element
    }
}

public enum AXWindowEnumerator {
    /// Reads the open windows of the running app with the given bundle
    /// identifier, in raw AX-array order, with no identity assigned yet.
    /// Returns an empty array if the app isn't running or has no open
    /// windows.
    ///
    /// Pure AX-tree reading only. Assigning stable cross-poll ids is
    /// `WindowIdentityTracker`'s job (see `Watcher`) — the AX windows array's
    /// order isn't stable across polls and titles can change, so neither can
    /// serve as an id source.
    public static func rawWindows(forBundleIdentifier bundleIdentifier: String) -> [AXUIElementAdapter] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            return []
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Electron/Chromium apps only expose their full web-content AX tree
        // when AXEnhancedUserInterface is set on the application element.
        // Without this, the AX tree contains only the window chrome (14 nodes)
        // and none of the chat-UI content. Setting it is idempotent and safe
        // to call on every poll — Electron ignores it if it's already set.
        AXUIElementSetAttributeValue(appElement,
                                     "AXEnhancedUserInterface" as CFString,
                                     kCFBooleanTrue)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }

        return windows.map { AXUIElementAdapter($0) }
    }
}
