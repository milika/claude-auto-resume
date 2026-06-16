import Foundation
import ClaudeAutoResumeCore

/// Pure-string variant of the Claude Code rate-limit detection logic.
///
/// Where `RateLimitDetector` walks an `AccessibilityElement` tree looking for
/// banner-shaped text inside Claude Desktop's Chromium DOM, Claude Code in a
/// terminal exposes its UI as one big `AXTextArea` whose `AXValue` is the
/// entire scrollback. Detection for the terminal case is pure substring work:
///
/// 1. Find the last occurrence of the banner-keyword phrase in the scrollback
///    ("session limit", "usage limit", "rate limit" — with terminal-specific
///    exclusions for false-positives like Claude Code's own status messages).
/// 2. Read the next 1-2 lines for a parseable reset time (the same formats
///    `ResetTimeParser` already handles for Claude Desktop).
///
/// Detection deliberately does NOT walk the scrollback line-by-line looking
/// for the bottommost banner: Claude Code's TUI can scroll old output out of
/// the buffer, and the most recent banner-shaped text in the visible buffer
/// is the one that actually matters for the user.
public enum TerminalRateLimitDetector {
    public enum Result: Equatable {
        case none
        /// Banner-shaped text was found but no parseable reset time was on the
        /// next 1-2 lines. We log this so we can spot format drift early.
        case unrecognized(rawText: String)
        /// A real rate-limit banner with a parseable reset time.
        case rateLimited(resetAt: Date, rawText: String)
    }

    /// Phrases that identify a Claude Code rate-limit banner line. The
    /// `reset` / `resets` requirement is what excludes the `/upgrade to
    /// increase your usage limit.` follow-up line — that line contains
    /// "usage limit" but no reset time, and is *not* the banner.
    ///
    /// The bare "rate limit" phrase is intentionally NOT in this list:
    /// Claude Code's session sidebar / status messages use it generically
    /// and we'd false-positive constantly.
    private static let bannerKeywords: [String] = [
        "session limit · resets",
        "usage limit · resets",
        "session limit · reset",
        "usage limit · reset",
        "you've hit your session limit",
        "you've hit your usage limit",
    ]

    /// Public for testing.
    public static let linesToSearchAfterBanner = 3

    public static func detect(in scrollback: String, now: Date = Date(),
                              calendar: Calendar = .current) -> Result {
        let lines = scrollback.components(separatedBy: "\n")
        guard !lines.isEmpty else { return .none }

        // Find the bottommost line that contains a banner keyword AND is
        // within the last few lines of the buffer (Claude Code's most-recent
        // response is what we care about — old output scrolled up isn't a
        // current rate limit, even if it once was).
        //
        // We look in the LAST `linesToSearchAfterBanner * 2` lines, capped
        // to the buffer length. The "bottommost" rule from
        // `RateLimitDetector` applies in spirit: when two banners are
        // present, take the most recent.
        let recentWindow = max(40, linesToSearchAfterBanner * 6)
        let startIndex = max(0, lines.count - recentWindow)
        let recentLines = Array(lines[startIndex..<lines.count])

        guard let hit = bottommostLineIndex(matchingAny: bannerKeywords, in: recentLines) else {
            return .none
        }

        // The banner may be on this line or split across this + next. Read
        // the banner line and the next `linesToSearchAfterBanner` lines as
        // one search block.
        let absHit = startIndex + hit
        let endSearch = min(lines.count, absHit + 1 + linesToSearchAfterBanner)
        let searchBlock = lines[absHit..<endSearch].joined(separator: " ")

        // The banner rawText is the keyword line (decoration stripped). We
        // keep it short — just the banner line + reset line, not the whole
        // search block — so the activity log stays readable.
        let bannerLine = lines[absHit].trimmingCharacters(in: .whitespaces)
        let rawText = bannerLine

        if let resetAt = ResetTimeParser.parse(searchBlock, now: now, calendar: calendar) {
            return .rateLimited(resetAt: resetAt, rawText: rawText)
        }

        return .unrecognized(rawText: rawText)
    }

    /// Returns the *bottommost* (largest-index) line index in `lines` that
    /// contains any of `keywords` as a case-insensitive substring. Skips
    /// lines that are clearly decoration (a leading `⎿ ` from Claude Code's
    /// result block is fine — that's actual content; but the previous-user-
    /// input echo and pure prompt decoration are not banner lines, and we
    /// don't want to match them either). Returns nil if no match.
    private static func bottommostLineIndex(matchingAny keywords: [String],
                                           in lines: [String]) -> Int? {
        for i in lines.indices.reversed() {
            let lower = lines[i].lowercased()
            for keyword in keywords {
                if lower.contains(keyword) {
                    return i
                }
            }
        }
        return nil
    }
}
