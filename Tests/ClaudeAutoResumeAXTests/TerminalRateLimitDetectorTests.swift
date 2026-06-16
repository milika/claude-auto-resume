import XCTest
@testable import ClaudeAutoResumeAX
@testable import ClaudeAutoResumeCore

/// Live-captured scrollback from `com.apple.Terminal` running `claude`
/// (Claude Code v2.1.168). The full ~2KB buffer the user saw right when the
/// rate limit was hit — including the "Fable unavailable / Opus 4.8" notice,
/// the welcome screen, the user's `hi` input echoed back, and the
/// `⎿  You've hit your session limit · resets 2:10pm` banner with the
/// `/upgrade` follow-up.
///
/// This fixture exists so the detector is locked to real evidence, not to
/// guesses about what Claude Code's TUI looks like. Update it whenever the
/// banner format is observed to change. Personal details in the captured
/// scrollback are anonymized to placeholder values; if you re-capture
/// from a real session, do the same before committing.
private let capturedScrollback = """
Last login: Mon Jun 15 18:55:19 on ttys005
user@host ~ % claude
╭─── Claude Code v2.1.168 ─────────────────────────────────────────────────────╮
│                                                    │ Tips for getting        │
│                                                    │ Tips for getting        │
│                Welcome back!                        │ started                 │
│                                                    │ Run /init to create a … │
│                      ▗ ▗   ▖ ▖                     │ Note: You have launche… │
│                                                    │ ─────────────────────── │
│                        ▘▘ ▝▝                       │ What's new              │
│                                                    │ Added `Tool(param:valu… │
│ Sonnet 4.6 · Claude Pro · test@example.com's        │ Skills in nested `.cla… │
│ Organization                                       │ Nested `.claude/` dire… │
│                 /Users/testuser                     │ /release-notes for more │
╰──────────────────────────────────────────────────────────────────────────────╯

   Claude Fable 5 is currently unavailable. Please use Opus 4.8 or another
   available model. Learn more:
   https://www.anthropic.com/news/fable-mythos-access
 ⚠ 1 setup issue: MCP · /doctor

 ▎ Opus 4.8 is now available! · /model to switch

❯ hi
  ⎿  You've hit your session limit · resets 2:10pm
     /upgrade to increase your usage limit.

✻ Sautéed for 0s

❯ hi
  ⎿  You've hit your session limit · resets 2:10pm
     /upgrade to increase your usage limit.

✻ Worked for 0s

────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
"""

final class TerminalRateLimitDetectorTests: XCTestCase {
    /// "now" is 2026-06-16 08:46 UTC. The bottommost banner says
    /// "resets 2:10pm" with no timezone annotation, so ResetTimeParser parses
    /// it in `calendar`'s timezone (UTC), giving 14:10 UTC — 5h 24m in the
    /// future. Built from explicit components in UTC so the test is
    /// timezone-stable.
    private lazy var now: Date = {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 16
        comps.hour = 8
        comps.minute = 46
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// The bottommost banner in the captured scrollback has a parseable
    /// reset time on the same line. The detector must find it (not the
    /// older banner) and return it as `.rateLimited`.
    func testDetectsBottommostRateLimitedBannerWithResetTime() {
        let result = TerminalRateLimitDetector.detect(in: capturedScrollback, now: now, calendar: calendar)
        guard case .rateLimited(let resetAt, let rawText) = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
        // The bottommost banner reads "resets 2:10pm" with no timezone
        // annotation, so ResetTimeParser parses it in `calendar`'s
        // timezone (UTC), giving 14:10 UTC.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 16
        comps.hour = 14
        comps.minute = 10
        comps.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(resetAt, expected)
        XCTAssertTrue(rawText.contains("session limit"), "rawText should reference the banner phrase: \(rawText)")
    }

    /// When the scrollback has no banner phrase at all, return `.none`
    /// — no false-positive on a normal "hi"/"hello" exchange.
    func testReturnsNoneWhenNoBanner() {
        let scrollback = """
        ❯ hi
          ⎿  Hello! How can I help you today?

        ✻ Worked for 2s

        ❯
        """
        let result = TerminalRateLimitDetector.detect(in: scrollback, now: now, calendar: calendar)
        XCTAssertEqual(result, .none)
    }

    /// The Claude Code v2.1.x banner says "session limit" — make sure
    /// the detector also matches the "usage limit" variant that Desktop
    /// uses, since Anthropic has been known to rotate phrasing.
    func testMatchesUsageLimitVariant() {
        let scrollback = """
        ❯ hi
          ⎿  You've hit your usage limit · resets 3:00 PM
             /upgrade to increase your usage limit.
        """
        let result = TerminalRateLimitDetector.detect(in: scrollback, now: now, calendar: calendar)
        guard case .rateLimited = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
    }

    /// Banner-shape text without a parseable reset time should return
    /// `.unrecognized` so the activity log records the format drift
    /// (so we'd notice if Anthropic changes the format).
    func testReturnsUnrecognizedWhenBannerHasNoParseableTime() {
        let scrollback = """
        ❯ hi
          ⎿  You've hit your session limit
             Please try again later.
        """
        let result = TerminalRateLimitDetector.detect(in: scrollback, now: now, calendar: calendar)
        guard case .unrecognized = result else {
            return XCTFail("expected .unrecognized, got \(result)")
        }
    }

    /// When two banners are present (an older scrolled-up one and a newer
    /// one), the bottommost (most recent) wins. This mirrors the Y-tolerance
    /// "bottommost banner selection" rule from `RateLimitDetector`.
    func testPicksBottommostBannerWhenMultiplePresent() {
        let olderBanner = "❯ earlier-msg\n  ⎿  You've hit your session limit · resets 5:00 AM"
        let newerBanner = "❯ later-msg\n  ⎿  You've hit your session limit · resets 4:00 PM"
        let scrollback = olderBanner + "\n" + newerBanner
        let result = TerminalRateLimitDetector.detect(in: scrollback, now: now, calendar: calendar)
        guard case .rateLimited(let resetAt, _) = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
        // Newer banner: 4:00 PM UTC = 16:00 UTC. Older banner: 5:00 AM UTC
        // is in the past (it's 08:46 UTC now), so picking it would schedule
        // a "resume now" instead of waiting. Verify we picked the 4 PM one.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 16
        comps.hour = 16
        comps.minute = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(resetAt, expected, "should pick the bottommost (4 PM) banner, not the earlier 5 AM one")
    }

    /// Pure-banner text without the IANA-timezone annotation should also
    /// parse correctly. ResetTimeParser.parseAbsoluteTime handles this.
    func testDetectsBannerWithoutTimezoneAnnotation() {
        let scrollback = """
        ❯ hi
          ⎿  You've hit your session limit · resets 3:00 PM
        """
        let result = TerminalRateLimitDetector.detect(in: scrollback, now: now, calendar: calendar)
        guard case .rateLimited(let resetAt, _) = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
        // 3:00 PM in calendar's timezone (UTC) = 15:00 UTC.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 16
        comps.hour = 15
        comps.minute = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(resetAt, expected)
    }
}
