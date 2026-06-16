import ServiceManagement

enum LoginItemRegistration {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("claude-auto-resume: failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
