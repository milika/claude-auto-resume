import AppKit
import ClaudeAutoResumeCore

/// Periodically checks whether to show the Ko-fi support nag, and presents
/// it via `NSAlert` when `KofiNagPolicy` says it's time.
final class KofiNagController {
    private static let checkInterval: TimeInterval = 3600
    private var timer: Timer?

    /// Performs an immediate check, then re-checks hourly so a long-running
    /// instance still notices day rollovers and the 5-day threshold passing.
    func start() {
        checkAndPresentIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.checkAndPresentIfNeeded()
        }
    }

    private func checkAndPresentIfNeeded() {
        let now = Date()
        guard KofiNagPolicy.shouldShow(now: now,
                                        firstLaunchDate: KofiNagState.firstLaunchDate,
                                        lastShownDate: KofiNagState.lastShownDate,
                                        dismissedPermanently: KofiNagState.dismissedPermanently) else {
            return
        }

        KofiNagState.lastShownDate = now

        let alert = NSAlert()
        alert.messageText = "Enjoying ClaudeAutoResume?"
        alert.informativeText = "If this app has been saving you time, consider buying me a coffee on Ko-fi — it really helps keep this project going. ☕"
        alert.addButton(withTitle: "Open Ko-fi")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            KofiNagState.dismissedPermanently = true
            NSWorkspace.shared.open(KofiNagState.kofiURL)
        }
    }
}
