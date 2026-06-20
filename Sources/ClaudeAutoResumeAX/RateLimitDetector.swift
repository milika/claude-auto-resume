import Foundation
import ClaudeAutoResumeCore

public enum RateLimitDetector {
    public enum Result: Equatable {
        case none
        /// Banner-shaped text was found but no reset time could be parsed from it.
        case unrecognized(rawText: String)
        case rateLimited(resetAt: Date, rawText: String)
    }

    /// Phrases that indicate a rate-limit banner is present, independent of
    /// whether a reset time can be parsed from the surrounding text.
    ///
    /// Deliberately excludes the bare phrase "rate limit": every genuine
    /// banner observed matches one of the entries below instead, while
    /// "rate limit" alone is generic enough to collide with unrelated
    /// session/tab names (e.g. a Claude Code session named "rate limit
    /// recovery"). `"session limit"` is included because Claude Desktop
    /// also renders the banner as `"You've hit your session limit · resets
    /// 1:40am (Europe/Belgrade)"` — observed missed on 2026-06-19 21:33
    /// when only the unmerged keywords were listed.
    private static let bannerKeywords = [
        "usage limit",
        "session limit",
        "server is temporarily limiting requests",
    ]

    /// Genuine banners lead with their key phrase ("Usage limit reached",
    /// "Server is temporarily limiting requests"). Text that only *mentions*
    /// or quotes one of `bannerKeywords` deep within a longer sentence — e.g.
    /// a leftover chat message describing a past detection — should not
    /// match. Requiring the keyword to appear near the start of the text
    /// distinguishes banner labels from prose that references them.
    private static let maxBannerKeywordOffset = 32

    public static func detect(in root: AccessibilityElement, now: Date = Date(),
                              calendar: Calendar = .current) -> Result {
        // Find the BOTTOMMOST (most recent) banner. Older rate-limit events
        // remain in the AX tree above it; taking the first DFS match picks the
        // oldest banner and can pull in reset times from old expanded panels.
        let allBanners = AXTreeWalker.findAll(in: root) { element in
            guard let text = displayText(of: element) else { return false }
            guard !isQuotedText(text) else { return false }
            let lowered = text.lowercased()
            // "Approaching X limit" banners are informational warnings shown
            // well before any limit is hit — Claude keeps working normally.
            // Exclude them so "approaching weekly usage limit" doesn't match
            // the "usage limit" keyword.
            guard !lowered.contains("approaching") else { return false }
            return bannerKeywords.contains { keyword in
                guard let range = lowered.range(of: keyword) else { return false }
                guard !isInlineQuoted(lowered, range: range) else { return false }
                let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                return offset < maxBannerKeywordOffset
            }
        }
        guard let bannerElement = allBanners.max(by: { ($0.frame?.minY ?? -1) < ($1.frame?.minY ?? -1) }),
              let rawText = displayText(of: bannerElement) else {
            // No element matched any `bannerKeywords`. Fall back to the inline
            // banner scan, which catches the merged-element shape where the
            // banner phrasing is new to us (e.g. "Daily limit reached · Resets
            // 3pm"). Without this, Claude changing the banner phrasing would
            // silently turn every future rate limit invisible — exactly the
            // regression that hid the 2026-06-19 21:33 limit.
            return detectInlineBanner(in: root, now: now, calendar: calendar)
        }

        if let resetAt = ResetTimeParser.parse(rawText, now: now, calendar: calendar) {
            return .rateLimited(resetAt: resetAt, rawText: rawText)
        }

        // The banner's own text carries no reset time — scan the rest of the
        // tree for any element whose text *is* parseable, so a reset time
        // shown in a separate sibling element is picked up.
        let bannerMinY = bannerElement.frame?.minY ?? -1
        if let detail = findNearbyParseableReset(in: root, belowOrNear: bannerMinY,
                                                  now: now, calendar: calendar) {
            return .rateLimited(resetAt: detail.resetAt, rawText: detail.rawText)
        }

        return .unrecognized(rawText: rawText)
    }

    /// Elements whose text contains a parseable reset time but sit more than
    /// this many points away from the banner's Y position are assumed to
    /// belong to an unrelated card (an old expanded panel, or a separate
    /// "Approaching ..." warning) rather than this banner's own detail.
    private static let nearbyResetTolerance: CGFloat = 300

    /// Genuine "Resets ..." detail elements are short labels — the longest
    /// observed in the wild is around 65 characters. A chat message
    /// *discussing* this detector can quote that same phrase deep within a
    /// much longer sentence; excluding long text prevents such prose from
    /// being mistaken for the banner's own detail.
    private static let maxNearbyResetTextLength = 100

    /// Scans for elements whose text contains a parseable reset time, but only
    /// considers elements within `nearbyResetTolerance` of the banner's Y
    /// position — not old expanded panels or unrelated warnings elsewhere in
    /// the tree that happen to contain a "Resets ..." string.
    ///
    /// If the banner element has no position info (`bannerMinY <= 0`),
    /// position filtering is skipped entirely — the reset-time element may
    /// render in an unexpected location and there's nothing to compare it
    /// against.
    private static func findNearbyParseableReset(in root: AccessibilityElement,
                                                  belowOrNear bannerMinY: CGFloat,
                                                  now: Date,
                                                  calendar: Calendar) -> (resetAt: Date, rawText: String)? {
        let candidates = AXTreeWalker.findAll(in: root) { element in
            guard let text = displayText(of: element) else { return false }
            guard !isQuotedText(text) else { return false }
            guard text.count <= maxNearbyResetTextLength else { return false }
            guard ResetTimeParser.parse(text, now: now, calendar: calendar) != nil else { return false }
            guard bannerMinY > 0 else { return true }
            guard let frame = element.frame else { return false }
            return abs(frame.minY - bannerMinY) <= nearbyResetTolerance
        }
        guard let element = candidates.max(by: { ($0.frame?.minY ?? -1) < ($1.frame?.minY ?? -1) }),
              let rawText = displayText(of: element),
              let resetAt = ResetTimeParser.parse(rawText, now: now, calendar: calendar) else {
            return nil
        }
        return (resetAt, rawText)
    }

    /// Defense-in-depth keywords used by `detectInlineBanner` when the main
    /// `bannerKeywords` list finds nothing. Broader than the primary list
    /// because the inline fallback *also* requires a parseable reset time in
    /// the same short element — a coincidence that chat prose and sidebar
    /// labels never satisfy — so we can afford to be more permissive.
    ///
    /// `"limit"` is included to catch future Claude phrasings like "Daily
    /// limit reached · Resets 3pm" without us having to update the primary
    /// keyword list. `"throttl"` covers "throttled" / "throttling" /
    /// "throttle" in any form Claude might shift to.
    private static let inlineBannerKeywords = ["limit", "throttl"]

    /// Inline-shape banners and detail labels are short — the longest genuine
    /// merged banner observed is around 65 characters. A chat message that
    /// *discusses* a rate limit can easily quote the same shape in a longer
    /// sentence, so we cap aggressively to keep prose out.
    private static let maxInlineBannerTextLength = 100

    /// Scans the tree for an element whose text *simultaneously* carries a
    /// parseable reset time inline AND contains a limit/throttle-shaped
    /// keyword near the start. Catches the merged-element banner shape where
    /// Claude renders `"<banner phrasing> · resets 1:40am (Europe/Belgrade)"`
    /// as a single AX text element rather than a banner element plus a sibling
    /// reset-time element. When the banner phrasing is unknown to
    /// `bannerKeywords` (a regression class first seen on 2026-06-19 21:33
    /// when Claude's banner read `"You've hit your session limit · resets
    /// 1:40am"`), the standard two-step detection finds nothing and this
    /// fallback is the only thing that recovers the resume.
    ///
    /// Picks the bottommost match by `frame.minY` to match the same
    /// "most recent on screen" rule the primary path uses for `allBanners`.
    private static func detectInlineBanner(in root: AccessibilityElement,
                                            now: Date,
                                            calendar: Calendar) -> Result {
        let candidates = AXTreeWalker.findAll(in: root) { element in
            guard let text = displayText(of: element) else { return false }
            guard !isQuotedText(text) else { return false }
            guard text.count <= maxInlineBannerTextLength else { return false }
            let lowered = text.lowercased()
            // Same "approaching" guard as the primary path: informational
            // warnings like "Approaching weekly usage limit · Resets ..." must
            // not fire the fallback even though they fit every other shape.
            guard !lowered.contains("approaching") else { return false }
            // Require a parseable reset time inline. Without this requirement
            // we'd match anything containing "limit" — sidebar labels, chat
            // references, status pills — and falsely schedule resumes.
            guard ResetTimeParser.parse(text, now: now, calendar: calendar) != nil else { return false }
            return inlineBannerKeywords.contains { keyword in
                guard let range = lowered.range(of: keyword) else { return false }
                guard !isInlineQuoted(lowered, range: range) else { return false }
                let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                return offset < maxBannerKeywordOffset
            }
        }
        guard let bannerElement = candidates.max(by: { ($0.frame?.minY ?? -1) < ($1.frame?.minY ?? -1) }),
              let rawText = displayText(of: bannerElement),
              let resetAt = ResetTimeParser.parse(rawText, now: now, calendar: calendar) else {
            return .none
        }
        return .rateLimited(resetAt: resetAt, rawText: rawText)
    }

    /// True if the keyword match at `range` within `text` is immediately
    /// bracketed by a matching pair of `"` or `'` characters — e.g. a chat
    /// message asking `Do you see a "Server is temporarily limiting
    /// requests" banner?` renders that quoted phrase near the start of an
    /// otherwise-unquoted sentence. Unlike `isQuotedText`, which only catches
    /// whole-text quoting, this catches a keyword phrase quoted inline within
    /// a longer sentence.
    private static func isInlineQuoted(_ text: String, range: Range<String.Index>) -> Bool {
        guard range.lowerBound > text.startIndex, range.upperBound < text.endIndex else { return false }
        let before = text[text.index(before: range.lowerBound)]
        let after = text[range.upperBound]
        return (before == "\"" && after == "\"") || (before == "'" && after == "'")
    }

    /// True if `text`, once trimmed, is itself wrapped in a matching pair of
    /// `"` or `'` characters. No genuine banner or detail label is wrapped in
    /// literal quote marks — that shape only arises from a quoted string
    /// literal in displayed source code (e.g. a syntax-highlighted excerpt of
    /// this detector's own test file shown in a chat transcript) or quoted
    /// prose. Such text must never be treated as banner or detail text.
    private static func isQuotedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return false }
        return (first == "\"" && last == "\"") || (first == "'" && last == "'")
    }

    /// The text an element displays to the user — its `value` if non-empty,
    /// otherwise its `title`. Treats empty strings the same as nil so that
    /// elements with `value=""` (common in Electron/Chromium AX trees) fall
    /// back to `title` rather than returning an empty match.
    private static func displayText(of element: AccessibilityElement) -> String? {
        if let v = element.value, !v.isEmpty { return v }
        if let t = element.title, !t.isEmpty { return t }
        return nil
    }
}
