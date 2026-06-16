import ApplicationServices

public enum AccessibilityPermission {
    /// True if this process currently has Accessibility permission.
    public static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// True if granted; if not, prompts the user via the system dialog that
    /// links to System Settings → Privacy & Security → Accessibility.
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
