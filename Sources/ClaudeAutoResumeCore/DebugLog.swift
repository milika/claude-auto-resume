import Foundation

/// Shared writer for `~/Library/Application Support/ClaudeAutoResume/debug.log`.
///
/// Lives in `ClaudeAutoResumeCore` so both the `ClaudeAutoResumeAX` actuator
/// (which runs in-process and has no direct access to the app's logging
/// helpers) and the `ClaudeAutoResumeApp` `Watcher` can append diagnostic
/// lines without each one duplicating the file-handle dance.
///
/// Writes are best-effort: failures are swallowed so a debug-log write
/// never breaks the caller's flow. Output is `ISO8601` UTC + the supplied
/// line, terminated with a newline, mirroring the format the `Watcher`
/// was writing before this helper existed (so old log readers keep working).
public enum DebugLog {
    private static let lock = NSLock()
    private static var cachedURL: URL?

    private static func resolveURL() -> URL? {
        if let cachedURL { return cachedURL }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeAutoResume", isDirectory: true)
        // The directory is created by the App at startup. If for some reason
        // it doesn't exist yet (e.g. an AX module is invoked in a test
        // harness with no App container), create it ourselves so writes
        // don't silently disappear.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug.log")
        cachedURL = url
        return url
    }

    /// Appends `line` (verbatim) to `debug.log`, prefixed with the current
    /// time in ISO-8601 UTC. Uses `print` as well so the line is visible in
    /// Console.app / `log stream` when running from Xcode.
    public static func append(_ line: String) {
        // Console-side echo — same shape the Watcher's old inline writer
        // produced, so `log stream --predicate ... --level debug` keeps
        // picking it up.
        print("Debug - \(line)")
        guard let url = resolveURL() else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "\(ts) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }

        // Serialize concurrent appends from the AX and App targets — without
        // this, an interleaved write can drop characters at the boundary.
        lock.lock()
        defer { lock.unlock() }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
