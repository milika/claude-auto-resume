import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var watcher: Watcher?
    private var updaterManager: UpdaterManager?
    private var kofiNagController: KofiNagController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon

        let updaterManager = UpdaterManager()
        self.updaterManager = updaterManager

        let menuBarController = MenuBarController(
            openLogAction: { [weak self] in self?.watcher?.showLogWindow() },
            cancelAction: { [weak self] windowID in self?.watcher?.cancelResume(windowID: windowID) },
            quitAction: { NSApp.terminate(nil) },
            checkForUpdatesAction: updaterManager.isAvailable
                ? { [weak updaterManager] in updaterManager?.checkForUpdates() }
                : nil
        )
        self.menuBarController = menuBarController

        if !LoginItemRegistration.isEnabled() {
            LoginItemRegistration.setEnabled(true)
        }

        let watcher = Watcher(menuBarController: menuBarController)
        self.watcher = watcher
        watcher.start()

        KofiNagState.recordFirstLaunchIfNeeded()

        let kofiNagController = KofiNagController()
        self.kofiNagController = kofiNagController
        kofiNagController.start()
    }
}
