import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Thin wrapper around Sparkle's standard updater UI.
///
/// Sparkle (https://github.com/sparkle-project/Sparkle) is added to the
/// `ClaudeAutoResumeApp` Xcode target via *File ▸ Add Package
/// Dependencies…* (see the "Auto-updates" section of the project README).
/// Until that's done, `canImport(Sparkle)` is `false` and every member of
/// this type becomes a harmless no-op, so the rest of the app keeps building
/// normally even before the package dependency is added.
final class UpdaterManager {
#if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
#else
    init() {}
#endif

    /// Whether Sparkle is linked into this build — i.e. whether the
    /// "Check for Updates…" menu item should be shown at all.
    var isAvailable: Bool {
#if canImport(Sparkle)
        true
#else
        false
#endif
    }

    /// Shows Sparkle's standard "checking for updates" UI.
    func checkForUpdates() {
#if canImport(Sparkle)
        controller.checkForUpdates(nil)
#endif
    }
}
