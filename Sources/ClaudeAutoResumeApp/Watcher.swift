import AppKit
import ApplicationServices
import ClaudeAutoResumeCore
import ClaudeAutoResumeAX

/// Polls Claude Desktop for rate-limited windows, schedules resumes at the
/// parsed reset times, actuates them, and records everything to the activity
/// log. Owns the menu-bar summary text.
public final class Watcher {
    // Confirmed via `osascript -e 'id of app "Claude"'` with Claude Desktop
    // running — update this constant if that command returns a different value
    // on the machine where this is deployed (see Task 10's note).
    private static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"

    private let menuBarController: MenuBarController
    private let tracker = ConversationTracker()
    private let logStore: ActivityLogStore
    private let pollInterval: TimeInterval
    private let minimumResumeGap: TimeInterval
    private let suppressionCap: TimeInterval
    /// Maximum time into the future a resume may be scheduled. If the parsed
    /// reset time is farther away than this, the fire time is capped here so
    /// the window retries at the cap instead of waiting, e.g., 8+ hours.
    private let maximumScheduleAhead: TimeInterval
    /// How long to wait before retrying `performResume` when the attempt
    /// didn't complete (e.g. `.sendControlNotFound` — the UI hasn't caught up
    /// with the reported reset time yet). See `ResumeRetryPolicy`.
    private let resumeRetryBackoff: TimeInterval

    /// `CFEqual` on the window-level `AXUIElement` is the primary identity
    /// signal, but Claude Desktop's AX tree mutates when a throttle card's
    /// "View details"/"Try again" buttons are pressed: the *same* physical
    /// window's `AXUIElement` reference (and sometimes its title — it has
    /// been observed flipping between the conversation name and the generic
    /// "Claude") no longer `CFEqual`-matches on the very next poll. Without a
    /// fallback, that mints a fresh id for the window, the old id is reported
    /// as "closed" — cancelling its scheduled resume and wiping its tracked
    /// state — and the new id starts over at `.idle`.
    ///
    /// The window's on-screen frame is unaffected by its content re-rendering,
    /// so it survives this churn and is used as a fallback key: an element
    /// with no `CFEqual` match is matched to a previously-tracked element with
    /// the same (rounded) frame that also has no match this round, preserving
    /// its id — and with it, any `.rateLimited`/`.scheduled` state.
    ///
    /// `fallbackKey` only bridges a single poll-to-poll transition: if the
    /// window is missing from `kAXWindowsAttribute` for more than one poll
    /// (observed with macOS Space-switching), its id is gone for good and no
    /// frame match can recover it. For that case, `poll()` preserves any
    /// pending `.scheduled` resume's fire time by conversation title before
    /// discarding the stale id (`ConversationTracker.retire`), and whichever
    /// window — any id — later reappears with that same title adopts the
    /// deadline (`adoptOrphanedDeadline`), so the resume still fires.
    private let identityTracker = WindowIdentityTracker<AXUIElementAdapter>(
        isSame: { CFEqual($0.element, $1.element) },
        fallbackKey: { adapter in
            guard let frame = adapter.frame else { return nil }
            let x = Int(frame.origin.x.rounded())
            let y = Int(frame.origin.y.rounded())
            let width = Int(frame.size.width.rounded())
            let height = Int(frame.size.height.rounded())
            return AnyHashable("\(x),\(y),\(width),\(height)")
        }
    )
    /// The most recent poll's matched windows, keyed for title lookups in
    /// `updateSummary` and `log` — both of which need a window's *current*
    /// title but only have its (now-opaque) surrogate id to look it up by.
    private var lastKnownWindows: [TrackedWindow] = []
    /// Hash of the last terminal-window scrollback that produced a
    /// `.rateLimitDetected` log, so we don't log the same banner every
    /// 8 seconds. Keyed on the Terminal window's title string.
    private var lastTerminalRateLimitLog: [String: String] = [:]
    /// Pending terminal-sourced resume timers, keyed on the Terminal
    /// window's title. Milestone 2: when a terminal rate-limit banner is
    /// detected, we schedule a resume for the parsed reset time and arm
    /// a `DispatchSourceTimer` on the same background queue as the
    /// poll loop. (Terminal windows don't have stable AXUIElement
    /// surrogate ids like Claude Desktop, so we can't reuse the
    /// `ConversationTracker`-based scheduling; titles are stable enough
    /// for the v1 use case — one Claude session per Terminal window.)
    private var scheduledTerminalResumes: [String: DispatchSourceTimer] = [:]
    /// Per-title retry counts for terminal resumes that didn't verify.
    /// Mirrors `retryCounts` for the Claude Desktop path; cleared on a
    /// successful resume.
    private var terminalRetryCounts: [String: Int] = [:]
    /// Per-title stale flag — was the most recent resume for this
    /// window targeting a reset time that was already in the past at
    /// schedule time?
    private var terminalResumeWasStale: [String: Bool] = [:]

    private var pollTimer: DispatchSourceTimer?
    private var pollQueue: DispatchQueue
    private var pollActivityToken: NSObjectProtocol?
    /// Every `heartbeatInterval` polls, write a single line to `debug.log` so
    /// a future "the app went silent for hours" incident has evidence in the
    /// log of where the poll loop actually stopped, instead of forcing us to
    /// infer silence from the activity log.
    private var pollsSinceHeartbeat: Int = 0
    private static let heartbeatInterval: Int = 30
    private var scheduledResumes: [String: DispatchSourceTimer] = [:]
    /// Whether the most recently scheduled resume for a window targeted a
    /// `resetAt` already in the past at schedule time. Read and cleared by
    /// `performResume` to decide whether a `.sent` outcome should suppress
    /// further attempts (see `ResumeRetryPolicy`).
    private var pendingResumeWasStale: [String: Bool] = [:]
    /// Whether the most recent resume for a window ran with a stale AX handle
    /// (CGWindowList saw Claude on-screen but the AX element reported
    /// `frame=nil` or `role=AXApplication`). Set by `performResume`'s
    /// stale-handle detector and consumed by `ResumeRetryPolicy.action`, so
    /// `.inputNotFound` on a stale handle gets the long, renderer-friendly
    /// retry budget instead of the tight default (the 2026-06-19 14:40 case
    /// had Claude's renderer take the better part of a minute to repopulate
    /// its chat panel after the rate-limit countdown ended, far longer than
    /// the old 5×30s budget).
    private var pendingResumeHadStaleHandle: [String: Bool] = [:]
    /// Consecutive non-`.sent` resume outcomes for a window, for a reset time
    /// that hasn't passed. Incremented on `.retry`, cleared on any other
    /// outcome. Passed to `ResumeRetryPolicy` so a window stuck returning
    /// e.g. `.inputNotFound` forever eventually `.giveUp`s instead of
    /// retrying every `resumeRetryBackoff` seconds indefinitely.
    private var retryCounts: [String: Int] = [:]
    private var logWindow: NSWindow?

    public init(menuBarController: MenuBarController,
                pollInterval: TimeInterval = 8,
                minimumResumeGap: TimeInterval = 5,
                suppressionCap: TimeInterval = 6 * 3600,
                maximumScheduleAhead: TimeInterval = 6 * 3600,
                resumeRetryBackoff: TimeInterval = 30,
                logFileURL: URL = Watcher.defaultLogFileURL()) {
        self.menuBarController = menuBarController
        self.pollInterval = pollInterval
        self.minimumResumeGap = minimumResumeGap
        self.suppressionCap = suppressionCap
        self.maximumScheduleAhead = maximumScheduleAhead
        self.resumeRetryBackoff = resumeRetryBackoff
        self.logStore = ActivityLogStore(fileURL: logFileURL)
        // Dedicated serial queue for the poll loop. Using a background queue
        // (not the main run loop) keeps the timer firing even when the menu-bar
        // UI is idle, and is not subject to App Nap the way `Timer.scheduledTimer`
        // on the main run loop is. The `.userInitiated` activity token below
        // tells App Nap we genuinely need to keep running.
        self.pollQueue = DispatchQueue(label: "com.milikadelic.ClaudeAutoResume.poll", qos: .userInitiated)
    }

    public static func defaultLogFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeAutoResume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity-log.jsonl")
    }

    public func start() {
        let granted = AccessibilityPermission.isGranted()
        Self.appendDebugLog("[startup] start() called — AXIsProcessTrusted=\(granted) pid=\(ProcessInfo.processInfo.processIdentifier)")
        if granted {
            startPolling()
        } else {
            AccessibilityPermission.requestIfNeeded()
            menuBarController.update(summary: "⚠️ Accessibility permission required — open System Settings")
            // Retry every 3 seconds until the user grants permission.
            // Without this the app stays silent forever even after the user
            // grants permission in System Settings.
            startPermissionRetryTimer()
        }
    }

    /// Sets up a 3-second permission-retry timer on the same background queue
    /// as the poll loop. Lives there (not on the main run loop) so App Nap
    /// doesn't pause it the way it paused the old `Timer.scheduledTimer`.
    private func startPermissionRetryTimer() {
        cancelPollTimer()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let nowGranted = AccessibilityPermission.isGranted()
            Self.appendDebugLog("[startup] permission retry — AXIsProcessTrusted=\(nowGranted)")
            if nowGranted {
                self.cancelPollTimer()
                self.startPolling()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func startPolling() {
        menuBarController.update(summary: "Watching for rate limits…")
        Self.appendDebugLog("[startup] starting poll loop on background queue, interval=\(self.pollInterval)s")

        // Hold a `userInitiated` activity token while polling. macOS honors
        // this as "the user is actively waiting on this work" and won't App
        // Nap the process even when the display sleeps. We renew it every
        // poll (the assertion has no hard expiry, but the safest pattern is
        // to re-issue periodically so a code bug can't accidentally leak a
        // stale token and defeat the assertion).
        renewPollActivity()

        cancelPollTimer()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Hop to main for the actual poll work: `poll()` and `performResume()`
            // both touch AppKit (NSStatusItem, NSMenu, NSAlert) which must run
            // on the main thread. The timer itself fires on the background
            // queue, which is the App-Nap-defeating part — once the handler
            // runs, we're past the App Nap gating.
            DispatchQueue.main.async {
                self.poll()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Cancels the active poll timer (poll loop OR permission-retry loop).
    private func cancelPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Re-issues the userInitiated activity token used to keep the poll loop
    /// out of App Nap. Idempotent: releases any prior token before issuing
    /// a fresh one. Called once at poll-start and again every `heartbeatInterval`
    /// polls.
    private func renewPollActivity() {
        if let token = pollActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            pollActivityToken = nil
        }
        pollActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "watching Claude for rate-limit banners"
        )
    }

    public func showLogWindow() {
        let events = (try? logStore.loadAll()) ?? []
        let window = LogWindowFactory.makeWindow(events: events)
        logWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Reads the live AX window list, matches it against the previous poll's
    /// snapshot to assign stable surrogate ids (see `WindowIdentityTracker`),
    /// and refreshes `lastKnownWindows` for title lookups. The single entry
    /// point for AX window enumeration — both `poll()` and `performResume`
    /// go through it, so every id `Watcher` ever sees comes from the same
    /// stable-identity source.
    private func currentWindows() -> [TrackedWindow] {
        let adapters = AXWindowEnumerator.rawWindows(forBundleIdentifier: Self.claudeBundleIdentifier)
        let matched = identityTracker.match(adapters)
        let windows = matched.map { TrackedWindow(id: $0.id, title: $0.element.title, element: $0.element) }
        lastKnownWindows = windows
        return windows
    }

    /// Polls Claude Code running inside Terminal.app windows. Milestone 2:
    /// detect rate-limit banners in the scrollback, log them, and arm a
    /// resume timer for the parsed reset time. When the timer fires, run
    /// `TerminalResumeActuator.resume` and verify Claude accepted the
    /// message via the post-keystroke scrollback check.
    ///
    /// Each terminal window's scrollback is the entire visible buffer
    /// (exposed as a single `AXTextArea` by Terminal.app). We re-read it
    /// on every poll and run `TerminalRateLimitDetector` on the full text.
    /// Activity-log noise is controlled with a per-window hash of the last
    /// logged banner — we only emit a new event when the banner text
    /// changes, not on every poll.
    private func pollTerminalWindows() {
        let adapters = TerminalWindowSource.rawWindows()
        for adapter in adapters {
            guard let title = adapter.title else { continue }
            // The "id" for a terminal window is the AXUIElement pointer —
            // not stable across polls (each read returns a new pointer if
            // the element was rebuilt), but stable within a single poll and
            // sufficient for the activity log to attribute events. We use
            // the window's title as the dedup key instead.
            let pointerId = String(describing: adapter.element)
            guard let root = AXUIElementAdapter(adapter.element) as AccessibilityElement? else { continue }
            // Find the largest `AXTextArea` (the scrollback).
            let textAreas = AXTreeWalker.findAll(in: root) { $0.role == "AXTextArea" }
            let best = textAreas
                .compactMap { $0.value }
                .filter { !$0.isEmpty }
                .max(by: { $0.count < $1.count })
            guard let scrollback = best else { continue }

            let detection = TerminalRateLimitDetector.detect(in: scrollback)
            switch detection {
            case .none:
                // The banner is gone — the user (or a previous resume)
                // has cleared the rate-limit state. Cancel any pending
                // resume and clear the retry counter so the next
                // detection starts fresh.
                lastTerminalRateLimitLog.removeValue(forKey: title)
                cancelScheduledTerminalResume(for: title)
                terminalRetryCounts.removeValue(forKey: title)
                terminalResumeWasStale.removeValue(forKey: title)

            case .unrecognized(let rawText):
                let key = "\(title)\n\(rawText)"
                if lastTerminalRateLimitLog[title] != key {
                    lastTerminalRateLimitLog[title] = key
                    logTerminal(.unrecognizedState, windowID: pointerId, title: title, detail: rawText)
                }

            case .rateLimited(let resetAt, let rawText):
                let key = "\(title)\n\(rawText)\n\(resetAt.timeIntervalSince1970)"
                if lastTerminalRateLimitLog[title] != key {
                    lastTerminalRateLimitLog[title] = key
                    let detail = "Terminal/ClaudeCode: \(rawText) (resets \(resetAt))"
                    logTerminal(.rateLimitDetected, windowID: pointerId, title: title, detail: detail)
                    // Milestone 2: arm a resume timer at the parsed reset
                    // time. If a resume is already armed for this window,
                    // cancel it first — the new banner supersedes.
                    let now = Date()
                    terminalResumeWasStale[title] = resetAt <= now
                    if resetAt > now {
                        // Announce the schedule explicitly so the activity
                        // log shows *something* happened (otherwise the
                        // user only sees a detection event and a long
                        // quiet stretch until the resume — which looks
                        // like the system is dead).
                        logTerminal(.resumeScheduled, windowID: pointerId, title: title,
                                    detail: "Terminal/ClaudeCode: Resume scheduled for \(resetAt)")
                        armTerminalResume(title: title, fireAt: resetAt)
                    } else {
                        // Stale: the reset time is already in the past.
                        // Fire immediately on the background queue.
                        let now = Date()
                        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
                        timer.schedule(deadline: .now(), leeway: .milliseconds(50))
                        timer.setEventHandler { [weak self] in
                            DispatchQueue.main.async {
                                self?.performTerminalResume(title: title)
                            }
                        }
                        timer.resume()
                        // Replace any prior scheduled resume for this title.
                        scheduledTerminalResumes[title]?.cancel()
                        scheduledTerminalResumes[title] = timer
                    }
                }
            }
        }
    }

    /// Arms a one-shot `DispatchSourceTimer` on the same background queue
    /// as the poll loop, calling `performTerminalResume(title:)` at
    /// `fireAt`. Replaces any existing timer for `title`. The timer fires
    /// on the background queue (App-Nap-defeating), but the handler hops
    /// to main before invoking the resume because the actuator touches
    /// AppKit (`AXUIElementSetAttributeValue` for focus).
    private func armTerminalResume(title: String, fireAt: Date) {
        cancelScheduledTerminalResume(for: title)
        let interval = max(0, fireAt.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.performTerminalResume(title: title)
            }
        }
        timer.resume()
        scheduledTerminalResumes[title] = timer
    }

    private func cancelScheduledTerminalResume(for title: String) {
        scheduledTerminalResumes[title]?.cancel()
        scheduledTerminalResumes.removeValue(forKey: title)
    }

    /// Run the resume against the Terminal window with the given title.
    /// Mirrors the Claude Desktop `performResume` flow: invoke the
    /// actuator, log the outcome, apply the retry policy, schedule a
    /// retry if needed.
    private func performTerminalResume(title: String) {
        scheduledTerminalResumes.removeValue(forKey: title)

        // Find the current Terminal window with this title. The
        // AXUIElement reference changes per poll, so we re-enumerate
        // and match by title.
        let adapters = TerminalWindowSource.rawWindows()
        guard let adapter = adapters.first(where: { $0.title == title }) else {
            logTerminal(.windowClosed, windowID: title, title: title,
                        detail: "Terminal window disappeared before resume could run")
            terminalRetryCounts.removeValue(forKey: title)
            return
        }

        let outcome = TerminalResumeActuator.resume(window: adapter.element)
        logTerminal(.resumed, windowID: String(describing: adapter.element),
                    title: title, detail: "Outcome: \(outcome)")

        let wasStale = terminalResumeWasStale.removeValue(forKey: title) ?? false
        let retryCount = terminalRetryCounts[title] ?? 0
        switch ResumeRetryPolicy.action(for: outcome.toResumeOutcome(), wasStale: wasStale, retryBackoff: resumeRetryBackoff, retryCount: retryCount) {
        case .idle:
            terminalRetryCounts.removeValue(forKey: title)
            // Mark the rate-limit state as cleared so the next poll
            // doesn't re-detect and re-schedule.
            lastTerminalRateLimitLog.removeValue(forKey: title)

        case .retry(let delay):
            terminalRetryCounts[title] = retryCount + 1
            let retryAt = Date().addingTimeInterval(delay)
            logTerminal(.resumeScheduled, windowID: title, title: title,
                        detail: "Resume did not complete (\(outcome)); retrying at \(retryAt)")
            armTerminalResume(title: title, fireAt: retryAt)

        case .suppress:
            terminalRetryCounts.removeValue(forKey: title)
            logTerminal(.resumeSuppressed, windowID: title, title: title,
                        detail: "Sent 'continue' for an already-past reset time; suppressing further attempts until the banner clears")

        case .giveUp:
            terminalRetryCounts.removeValue(forKey: title)
            logTerminal(.resumeGaveUp, windowID: title, title: title,
                        detail: "Resume did not complete after 5 retries (\(outcome)); suppressing further attempts on this window until the banner clears")
        }
    }

    /// Activity-log writer for terminal-sourced events. Same shape as
    /// `log(_:windowID:detail:)` but takes a title directly (terminal
    /// windows aren't in `lastKnownWindows`).
    private func logTerminal(_ kind: ActivityEvent.Kind, windowID: String, title: String, detail: String) {
        let event = ActivityEvent(timestamp: Date(), windowID: windowID, windowTitle: title, kind: kind, detail: detail)
        try? logStore.append(event)
    }

    private func poll() {
        guard AccessibilityPermission.isGranted() else {
            log(.permissionLost, windowID: "-", detail: "Accessibility permission was revoked")
            cancelPollTimer()
            start()
            return
        }

        let previousWindows = lastKnownWindows
        let windows = currentWindows()
        let liveIDs = Set(windows.map(\.id))

        if Self.diagnosticRequested() {
            for window in windows {
                Self.appendDebugLog("[diagnose \(window.id) title=\(window.title ?? "nil")]")
                for line in AXTreeDiagnostics.describe(root: window.element) {
                    Self.appendDebugLog("[diagnose \(window.id)]   \(line)")
                }
            }
        }

        for staleID in tracker.allWindowIDs() where !liveIDs.contains(staleID) {
            cancelScheduledResume(for: staleID)
            let title = previousWindows.first(where: { $0.id == staleID })?.title
            tracker.retire(windowID: staleID, title: title)
            log(.windowClosed, windowID: staleID, detail: "Window no longer present")
        }

        for window in windows {
            switch tracker.state(for: window.id) {
            case .idle:
                if let fireAt = tracker.adoptOrphanedDeadline(windowID: window.id, title: window.title) {
                    pendingResumeWasStale[window.id] = fireAt <= Date()
                    armResumeTimer(windowID: window.id, fireAt: fireAt)
                    log(.resumeScheduled, windowID: window.id,
                        detail: "Adopted pending resume for \(fireAt) from a previous window instance with the same title")
                } else {
                    handleIdleWindow(window)
                }

            case .suppressed:
                handleSuppressedWindow(window)

            case .rateLimited, .scheduled, .resuming:
                continue
            }
        }

        // AppKit work (NSStatusItem / NSMenu / NSAlert updates) must run on
        // the main thread. `poll()` is invoked via `DispatchQueue.main.async`
        // from the background-queue timer, so we are already on main here.
        updateSummary()

        // Milestone 1 terminal-side detection. Detects rate-limit banners in
        // Claude Code running inside Terminal.app windows. Logs
        // `.rateLimitDetected` (and `.unrecognizedState`) to the activity
        // log; does NOT schedule resumes — that's Milestone 2. See
        // `docs/terminal-cli-support.md`.
        pollTerminalWindows()

        // Heartbeat + activity renewal. Once a minute (every `heartbeatInterval`
        pollsSinceHeartbeat += 1
        if pollsSinceHeartbeat >= Self.heartbeatInterval {
            let n = pollsSinceHeartbeat
            pollsSinceHeartbeat = 0
            Self.appendDebugLog("[heartbeat] poll #\(n) at \(Date())")
            renewPollActivity()
        }
    }

    /// Detects rate limits in a window not currently tracked as limited.
    private func handleIdleWindow(_ window: TrackedWindow) {
        let detection = RateLimitDetector.detect(in: window.element)
        switch detection {
        case .none:
            return

        case .unrecognized(let rawText):
            if tracker.shouldLogUnrecognized(windowID: window.id, rawText: rawText) {
                log(.unrecognizedState, windowID: window.id, detail: rawText)
            }

        case .rateLimited(let resetAt, let rawText):
            tracker.transition(windowID: window.id, to: .rateLimited(resetAt: resetAt))
            log(.rateLimitDetected, windowID: window.id, detail: rawText)
            scheduleResume(windowID: window.id, resetAt: resetAt)
        }
    }

    /// A window the user pressed "Stop" on. Generates no further scheduling
    /// while suppressed. Suppression ends the moment either of two things
    /// happens, whichever comes first:
    /// - the rate-limit banner disappears entirely (normal case), or
    /// - `suppressionCap` elapses since "Stop" was pressed (safety net, in
    ///   case banner-clearing is never detected — e.g. due to AX flakiness).
    private func handleSuppressedWindow(_ window: TrackedWindow) {
        guard case .suppressed(let since) = tracker.state(for: window.id) else { return }

        if Date().timeIntervalSince(since) >= suppressionCap {
            tracker.transition(windowID: window.id, to: .idle)
            log(.suppressionExpired, windowID: window.id,
                detail: "Suppression cap (\(suppressionCap)s) reached; resuming normal detection")
            return
        }

        guard case .none = RateLimitDetector.detect(in: window.element) else { return }
        tracker.transition(windowID: window.id, to: .idle)
        log(.suppressionCleared, windowID: window.id, detail: "Rate limit cleared; resuming normal detection")
    }

    private func scheduleResume(windowID: String, resetAt: Date) {
        let pendingEntries = tracker.allWindowIDs().compactMap { id -> (windowID: String, resetAt: Date)? in
            guard case .rateLimited(let at) = tracker.state(for: id) else { return nil }
            return (id, at)
        }
        let staggered = ResumeStaggering.staggeredFireTimes(for: pendingEntries, minimumGap: minimumResumeGap)

        let now = Date()
        let capDate = now.addingTimeInterval(maximumScheduleAhead)
        for fireTime in staggered {
            let effectiveFireAt = min(fireTime.fireAt, capDate)
            let wasCapped = effectiveFireAt < fireTime.fireAt

            tracker.transition(windowID: fireTime.windowID, to: .scheduled(fireAt: effectiveFireAt))
            pendingResumeWasStale[fireTime.windowID] = effectiveFireAt <= now

            if wasCapped {
                let hoursAhead = fireTime.fireAt.timeIntervalSinceNow / 3600
                log(.resumeScheduled, windowID: fireTime.windowID,
                    detail: String(format: "Reset time is %.1fh away — capped by 6h limit; will retry at %@",
                                   hoursAhead, "\(effectiveFireAt)"))
            } else {
                log(.resumeScheduled, windowID: fireTime.windowID,
                    detail: "Resume scheduled for \(effectiveFireAt)")
            }

            armResumeTimer(windowID: fireTime.windowID, fireAt: effectiveFireAt)
        }
    }

    private func performResume(windowID: String) {
        scheduledResumes.removeValue(forKey: windowID)
        tracker.transition(windowID: windowID, to: .resuming)

        guard let tracked = currentWindows().first(where: { $0.id == windowID }),
              let adapter = tracked.element as? AXUIElementAdapter else {
            log(.windowClosed, windowID: windowID, detail: "Window disappeared before resume could run")
            tracker.remove(windowID: windowID)
            updateSummary()
            return
        }

        // Stale-handle detector. When Claude's `kAXWindowsAttribute` is
        // briefly empty or returns a single stale reference (e.g. when the
        // renderer is busy or the window is off-Space), the adapter we get
        // back can have `role=AXApplication` (the app element, not a window)
        // or `frame=nil` (the AXUIElement exists but reports no geometry).
        // Calling the actuator on such a handle returns `.inputNotFound`
        // 6 times in a row (the 2026-06-18 22:10 case). Cross-check with
        // the WindowServer before retrying: if Claude also has no on-screen
        // window per `CGWindowList`, the window genuinely isn't there, and
        // a stronger nudge can't conjure it. Bail out, transition to
        // `.suppressed`, and let the next poll re-evaluate (when Claude's
        // window comes back, the next banner detection re-schedules).
        //
        // The 2026-06-19 14:40 case repeated this pattern after the
        // stronger-nudge escalation still didn't surface a chat input — the
        // renderer took long enough to repopulate that the 5×30s retry
        // window ran out. We now also hand the `cgBounds` to the actuator
        // so it can post a click at the on-screen center as part of the
        // nudge, and the actuator's new wait-loop polls the AX tree for
        // up to 12s after the activation steps instead of probing once.
        let adapterRole = adapter.role
        let adapterFrame = adapter.frame
        let looksStale = adapterRole == "AXApplication" || adapterFrame == nil
        var cgBounds: CGRect? = nil
        if looksStale {
            cgBounds = ClaudeWindowPresence.claudeOnScreenBounds()
            if cgBounds == nil {
                let detail = "Stale AX handle (role=\(adapterRole ?? "nil"), frame=\(adapterFrame == nil ? "nil" : "present")) and CGWindowList shows no Claude window on-screen. Will re-evaluate on the next poll; if Claude's window comes back, the banner will be re-detected and a fresh resume scheduled."
                Self.appendDebugLog("[staleHandle \(windowID)] \(detail)")
                log(.resumeGaveUp, windowID: windowID, detail: detail)
                retryCounts.removeValue(forKey: windowID)
                tracker.transition(windowID: windowID, to: .suppressed(since: Date()))
                updateSummary()
                return
            }
            // CGWindowList sees Claude but AX is stale. The stronger nudge
            // in the actuator (`NSRunningApplication.activate` →
            // `TransformProcessType`) might still wake it up. Log the
            // discrepancy and proceed — `cgBounds` is also handed to the
            // actuator so it can click the on-screen center before falling
            // back to process-level activation alone.
                Self.appendDebugLog("[staleHandle \(windowID)] AX handle is stale (role=\(adapterRole ?? "nil"), frame=\(adapterFrame == nil ? "nil" : "present")) but CGWindowList shows Claude on-screen at \(String(describing: cgBounds)). Trying actuator with stronger nudge.")
        }

        let resumeOutcome = ResumeActuator.resume(window: adapter.element, cgBounds: cgBounds)
        log(.resumed, windowID: windowID, detail: "Outcome: \(resumeOutcome)")

        // Remember whether THIS attempt had a stale handle, so the retry
        // policy can give `.inputNotFound` a longer recovery window when the
        // renderer is the bottleneck (vs. a transient AX hiccup, which the
        // tight default budget rides out fine). Cleared after the policy
        // consumes it, so subsequent unrelated resumes don't inherit it.
        pendingResumeHadStaleHandle[windowID] = looksStale

        if resumeOutcome == .inputNotFound {
            Self.appendDebugLog("[inputNotFound \(windowID) title=\(tracked.title ?? "nil")]")
            // Cross-reference CGWindowList at the point of failure so a
            // future post-mortem can tell whether Claude was on-screen but
            // AX refused to introspect it (the 2026-06-19 14:40 shape) vs.
            // genuinely gone. Without this we can't distinguish "renderer
            // is busy" from "AX permission lost".
            if let cgBounds {
                Self.appendDebugLog("[inputNotFound \(windowID)]   CGWindowList sees Claude on-screen at \(cgBounds)")
            } else {
                Self.appendDebugLog("[inputNotFound \(windowID)]   CGWindowList does not see Claude on-screen")
            }
            for line in AXTreeDiagnostics.describe(root: tracked.element) {
                Self.appendDebugLog("[inputNotFound \(windowID)]   \(line)")
            }
        }

        let wasStale = pendingResumeWasStale.removeValue(forKey: windowID) ?? false
        let staleHandle = pendingResumeHadStaleHandle.removeValue(forKey: windowID) ?? false
        let retryCount = retryCounts[windowID] ?? 0
        switch ResumeRetryPolicy.action(for: resumeOutcome, wasStale: wasStale, retryBackoff: resumeRetryBackoff, retryCount: retryCount, staleHandle: staleHandle) {
        case .idle:
            retryCounts.removeValue(forKey: windowID)
            tracker.transition(windowID: windowID, to: .idle)

        case .retry(let delay):
            retryCounts[windowID] = retryCount + 1
            let retryAt = Date().addingTimeInterval(delay)
            tracker.transition(windowID: windowID, to: .scheduled(fireAt: retryAt))
            log(.resumeScheduled, windowID: windowID,
                detail: "Resume did not complete (\(resumeOutcome)); retrying at \(retryAt)")
            armResumeTimer(windowID: windowID, fireAt: retryAt)

        case .suppress:
            retryCounts.removeValue(forKey: windowID)
            tracker.transition(windowID: windowID, to: .suppressed(since: Date()))
            log(.resumeSuppressed, windowID: windowID,
                detail: "Sent 'continue' for an already-past reset time; suppressing further attempts on this window until the banner clears or the suppression cap elapses")

        case .giveUp:
            retryCounts.removeValue(forKey: windowID)
            tracker.transition(windowID: windowID, to: .suppressed(since: Date()))
            log(.resumeGaveUp, windowID: windowID,
                detail: "Resume did not complete after \(ResumeRetryPolicy.maxRetries) retries (\(resumeOutcome)); suppressing further attempts on this window until the banner clears or the suppression cap elapses")
        }

        updateSummary()
    }

    private func cancelScheduledResume(for windowID: String) {
        scheduledResumes[windowID]?.cancel()
        scheduledResumes.removeValue(forKey: windowID)
    }

    /// Arms a one-shot `DispatchSourceTimer` on the same background queue as
    /// the poll loop, calling `performResume(windowID:)` at `fireAt`. Replaces
    /// any existing timer for `windowID`. The timer itself fires on the
    /// background queue (so App Nap can't delay it), but the handler hops to
    /// main before invoking `performResume()` because that function touches
    /// AppKit (`NSStatusItem` updates via `updateSummary()`).
    private func armResumeTimer(windowID: String, fireAt: Date) {
        cancelScheduledResume(for: windowID)
        let interval = max(0, fireAt.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.performResume(windowID: windowID)
            }
        }
        timer.resume()
        scheduledResumes[windowID] = timer
    }

    /// Cancels a single window's scheduled resume without affecting any other
    /// window. The window is parked in `.suppressed(since:)` — generating no
    /// further scheduling — until `handleSuppressedWindow` returns it to
    /// `.idle`, which happens when either the rate-limit banner disappears
    /// entirely or `suppressionCap` elapses, whichever comes first.
    /// (Returning straight to `.idle` here would let the very next poll
    /// re-detect the still-active limit and immediately reschedule, making
    /// Stop look like a no-op.)
    public func cancelResume(windowID: String) {
        cancelScheduledResume(for: windowID)
        tracker.transition(windowID: windowID, to: .suppressed(since: Date()))
        log(.resumeCancelled, windowID: windowID,
            detail: "Resume cancelled by user; suppressing further scheduling until the rate limit clears")
        updateSummary()
    }

    private func updateSummary() {
        let ids = tracker.allWindowIDs()
        let scheduledEntries = ids.compactMap { id -> ScheduledResumeDisplay.Entry? in
            guard case .scheduled(let fireAt) = tracker.state(for: id) else { return nil }
            let title = lastKnownWindows.first(where: { $0.id == id })?.title
            return ScheduledResumeDisplay.Entry(windowID: id,
                                                 displayName: ScheduledResumeDisplay.displayName(forTitle: title),
                                                 fireAt: fireAt)
        }.sorted { $0.fireAt < $1.fireAt }

        if let next = scheduledEntries.first {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            menuBarController.update(summary: "\(ids.count) watching · resumes at \(formatter.string(from: next.fireAt))",
                                     scheduledEntries: scheduledEntries)
        } else {
            menuBarController.update(summary: "Watching for rate limits…", scheduledEntries: scheduledEntries)
        }
    }

    private func log(_ kind: ActivityEvent.Kind, windowID: String, detail: String) {
        let title = lastKnownWindows.first(where: { $0.id == windowID })?.title
        let event = ActivityEvent(timestamp: Date(), windowID: windowID, windowTitle: title, kind: kind, detail: detail)
        try? logStore.append(event)
    }

    /// Checks for (and consumes) a one-shot diagnostic trigger file, dropped
    /// by hand to dump a read-only `AXTreeDiagnostics` summary of every
    /// tracked window's accessibility tree to `debug.log` on the next poll —
    /// no clicks or edits, safe to run against a live window.
    private static func diagnosticRequested() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeAutoResume", isDirectory: true)
        let url = dir.appendingPathComponent("diagnose-request")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// Appends a timestamped line to a dedicated debug log file separate from
    /// the main activity log — keeps noise out of the normal log while still
    /// persisting across polls for post-hoc analysis. Thin shim to
    /// `DebugLog.append` (in `ClaudeAutoResumeCore`) so the same writer can
    /// be used by the AX layer.
    static func appendDebugLog(_ line: String) {
        DebugLog.append(line)
    }
}
