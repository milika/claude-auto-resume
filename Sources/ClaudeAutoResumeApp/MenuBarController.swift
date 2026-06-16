import AppKit
import ClaudeAutoResumeCore

private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

/// Owns the NSStatusItem and renders a textual summary of tracked windows,
/// plus one cancellable line per currently-scheduled resume.
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let openLogAction: () -> Void
    private let cancelAction: (String) -> Void
    private let quitAction: () -> Void
    private let checkForUpdatesAction: (() -> Void)?
    private var currentSummary: String = "Watching for rate limits…"
    private var currentScheduledEntries: [ScheduledResumeDisplay.Entry] = []
    /// The most recently built menu. Stored here and popped up manually on
    /// button click — we never set `statusItem.menu` directly, because that
    /// causes the running menu to be closed and replaced on every 8-second
    /// poll cycle, making it impossible to click.
    private var latestMenu: NSMenu?

    /// - Parameter checkForUpdatesAction: When non-nil, a "Check for
    ///   Updates…" menu item is shown that invokes this closure. Pass `nil`
    ///   when Sparkle isn't linked into this build (see `UpdaterManager`).
    public init(openLogAction: @escaping () -> Void,
                cancelAction: @escaping (String) -> Void,
                quitAction: @escaping () -> Void,
                checkForUpdatesAction: (() -> Void)? = nil) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.openLogAction = openLogAction
        self.cancelAction = cancelAction
        self.quitAction = quitAction
        self.checkForUpdatesAction = checkForUpdatesAction
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleButtonClick(_:))
        setMenuBarIcon(hasScheduled: false)
        rebuildMenu(summary: "Watching for rate limits…", scheduledEntries: [])
    }

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        guard let menu = latestMenu else { return }
        // Pop the menu up manually. This is the only way to show the menu
        // without setting statusItem.menu, which would let AppKit close and
        // replace the menu on every poll cycle.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    /// Updates the status item's menu to reflect current tracked-window state.
    /// `summary` is a short human-readable line such as
    /// "2 watching · 1 resumes at 3:45 PM". `scheduledEntries` lists every
    /// currently-`.scheduled` window; each gets its own menu line with a
    /// "Stop" button that cancels just that resume.
    public func update(summary: String, scheduledEntries: [ScheduledResumeDisplay.Entry] = []) {
        currentSummary = summary
        currentScheduledEntries = scheduledEntries
        setMenuBarIcon(hasScheduled: !scheduledEntries.isEmpty)
        rebuildMenu(summary: summary, scheduledEntries: scheduledEntries)
    }

    /// Switches the menu bar button between a hourglass (waiting, nothing
    /// detected) and a recycle-arrows icon (rate limit detected, resume
    /// scheduled). Both are SF Symbol template images — macOS renders them
    /// in black or white automatically to match the menu bar appearance.
    private func setMenuBarIcon(hasScheduled: Bool) {
        let symbolName = hasScheduled ? "arrow.2.circlepath" : "hourglass"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true   // black in light mode, white in dark mode
            statusItem.button?.image = image
            statusItem.button?.title = ""
        }
    }

    private func rebuildMenu(summary: String, scheduledEntries: [ScheduledResumeDisplay.Entry]) {
        // If a popup is currently open, patch its top label in-place so the
        // user sees the updated summary immediately (e.g. after pressing Stop)
        // without waiting for the popup to close and reopen.
        latestMenu?.items.first?.title = summary

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: summary, action: nil, keyEquivalent: ""))

        for entry in scheduledEntries {
            let label = ScheduledResumeDisplay.lineLabel(displayName: entry.displayName, fireAt: entry.fireAt)
            let item = NSMenuItem()
            item.view = ScheduledResumeMenuItemView(label: label) { [weak self, weak item] in
                // Remove the row from the live open menu immediately rather than
                // waiting for the full rebuildMenu cycle that cancelAction triggers.
                if let item { item.menu?.removeItem(item) }
                self?.currentScheduledEntries.removeAll { $0.windowID == entry.windowID }
                self?.cancelAction(entry.windowID)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "ClaudeAutoResume v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let kofiItem = NSMenuItem(title: "☕ Support on Ko-fi", action: #selector(handleOpenKofi), keyEquivalent: "")
        kofiItem.target = self
        menu.addItem(kofiItem)

        if checkForUpdatesAction != nil {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(handleCheckForUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let loginItem = NSMenuItem(
            title: LoginItemRegistration.isEnabled() ? "✓ Launch at Login" : "Launch at Login",
            action: #selector(handleToggleLoginItem),
            keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let logItem = NSMenuItem(title: "Show Activity Log…", action: #selector(handleOpenLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        latestMenu = menu
    }

    @objc private func handleOpenLog() {
        openLogAction()
    }

    @objc private func handleQuit() {
        quitAction()
    }

    @objc private func handleCheckForUpdates() {
        checkForUpdatesAction?()
    }

    @objc private func handleOpenKofi() {
        KofiNagState.dismissedPermanently = true
        NSWorkspace.shared.open(KofiNagState.kofiURL)
    }

    @objc private func handleToggleLoginItem() {
        LoginItemRegistration.setEnabled(!LoginItemRegistration.isEnabled())
        rebuildMenu(summary: currentSummary, scheduledEntries: currentScheduledEntries)
    }
}

/// A menu-item view showing a scheduled-resume label and a "Stop" button side
/// by side — plain `NSMenuItem`s can't render a label and a control on one line.
private final class ScheduledResumeMenuItemView: NSView {
    private let onStop: () -> Void
    private weak var stopButton: NSButton?

    init(label: String, onStop: @escaping () -> Void) {
        self.onStop = onStop
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 22))

        let textField = NSTextField(labelWithString: label)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail

        let button = NSButton(title: "Stop", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(handleStop)
        stopButton = button

        addSubview(textField)
        addSubview(button)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: textField.trailingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleStop() {
        stopButton?.isEnabled = false
        onStop()
    }
}
