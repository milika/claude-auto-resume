import AppKit
import Foundation

// ── Single-instance enforcement ──────────────────────────────────────────────
// The app has no bundle ID (SPM executable), so the standard
// LSMultipleInstancesProhibited plist key doesn't apply. Instead we use a
// PID lock file: write our PID on launch, read it on the next launch to check
// whether that process is still alive via kill(pid, 0).
let lockURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeAutoResume", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("instance.lock")
}()

let myPID = ProcessInfo.processInfo.processIdentifier

if let lockData = try? Data(contentsOf: lockURL),
   let pidString = String(data: lockData, encoding: .utf8),
   let existingPID = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
   existingPID != myPID,
   kill(existingPID, 0) == 0 {
    // Another instance is already running — exit silently.
    exit(0)
}

// Claim the lock.
try? "\(myPID)".data(using: .utf8)?.write(to: lockURL, options: .atomic)

// ── Application entry point ───────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
