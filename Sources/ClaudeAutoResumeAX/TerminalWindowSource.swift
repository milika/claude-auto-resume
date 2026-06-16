import AppKit
import ApplicationServices
import Foundation

/// Enumerates Terminal.app's open windows, filters for those that look like
/// they're running Claude Code (or another Claude-family CLI), and produces
/// `TrackedWindow` values that the rest of the app can poll like a Claude
/// Desktop window.
///
/// Mirrors `AXWindowEnumerator`'s role for Claude Desktop (`com.anthropic.claudefordesktop`),
/// but for `com.apple.Terminal` and a fingerprint-based filter rather than
/// a bundle-id-only filter (a Terminal window's title changes with the
/// running process, and a user can have non-Claude Terminal windows we
/// should not watch).
///
/// The fingerprint is **defensive**: it requires both a title that mentions
/// "claude" AND a scrollback marker that confirms Claude Code is actually
/// the running child. Either alone is too loose — a user could `cd
/// ~/code/claude-fork` and the title would say "claude" without Claude being
/// involved, and Claude Code's banner could in principle be echoed into a
/// shell that ran `claude` as a one-off. Both must match.
///
/// The fingerprint marker string is "Claude Code v…" — the version banner
/// Claude Code prints on launch. (Example observed: `Claude Code v2.1.168`;
/// this string is the v-prefix Claude has used since v1.)
public enum TerminalWindowSource {
    /// Bundle id of the macOS Terminal app. Apple's default Terminal is the
    /// only adapter in v1; iTerm2 / Warp / kitty / Alacritty / Ghostty are
    /// documented as future work in `docs/terminal-cli-support.md`.
    public static let terminalBundleIdentifier = "com.apple.Terminal"

    /// Substring we look for in the Terminal window's `AXTitle` to suspect
    /// it might be running Claude. Case-insensitive.
    private static let titleHint = "claude"

    /// Substring we look for in the scrollback (the prompt's `AXValue`) to
    /// confirm the running child is actually Claude Code. Case-insensitive.
    private static let scrollbackMarker = "Claude Code v"

    /// Enumerates Terminal.app's Claude-Code windows. Returns an empty
    /// array if Terminal isn't running, isn't accessible, or has no
    /// matching windows.
    public static func rawWindows() -> [AXUIElementAdapter] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == terminalBundleIdentifier
        }) else {
            return []
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // `AXEnhancedUserInterface` is Electron-specific and doesn't apply
        // to Terminal, but the call is harmless and matches the pattern
        // used elsewhere in the app.
        AXUIElementSetAttributeValue(appElement,
                                     "AXEnhancedUserInterface" as CFString,
                                     kCFBooleanTrue)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement] else {
            return []
        }

        return windows.compactMap { window -> AXUIElementAdapter? in
            // Step 1: title hint. Cheap, no scrollback read.
            guard let title = stringAttribute(window, attribute: kAXTitleAttribute) else {
                return nil
            }
            guard title.lowercased().contains(titleHint) else { return nil }

            // Step 2: confirm the scrollback actually contains Claude
            // Code. Read the prompt element's `AXValue` (which exposes
            // the visible scrollback). The element lookup walks the AX
            // tree; if Terminal's layout changes this is the place that
            // breaks first.
            guard let scrollback = readScrollbackText(in: window) else {
                return nil
            }
            guard scrollback.lowercased().contains(scrollbackMarker.lowercased()) else {
                return nil
            }
            return AXUIElementAdapter(window)
        }
    }

    /// Read the visible scrollback text from a Terminal window. The prompt
    /// element's `AXValue` is the whole scrollback; we accept either the
    /// prompt or the upper read-only `AXTextArea` if both exist, and return
    /// the longest one.
    private static func readScrollbackText(in window: AXUIElement) -> String? {
        let root = AXUIElementAdapter(window)
        let textAreas = AXTreeWalker.findAll(in: root) { $0.role == "AXTextArea" }

        var best: String?
        for ta in textAreas {
            if let v = ta.value, !v.isEmpty {
                if best == nil || v.count > best!.count {
                    best = v
                }
            }
        }
        return best
    }

    private static func stringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }
}
