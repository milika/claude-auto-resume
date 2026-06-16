import XCTest
@testable import ClaudeAutoResumeAX

final class RateLimitDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testDetectsBannerAndParsesResetTime() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "You've reached your usage limit. Try again in 2 hours.")
            ])
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .rateLimited(let resetAt, let rawText) = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
        XCTAssertEqual(resetAt, now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(rawText, "You've reached your usage limit. Try again in 2 hours.")
    }

    func testReturnsUnrecognizedWhenBannerTextDoesNotParse() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text", value: "You've reached your usage limit. Please wait a bit and retry.")
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .unrecognized(let rawText) = result else {
            return XCTFail("expected .unrecognized, got \(result)")
        }
        XCTAssertEqual(rawText, "You've reached your usage limit. Please wait a bit and retry.")
    }

    func testReturnsUnrecognizedForThrottleCardBannerWithNoParseableTextAnywhere() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Server is temporarily limiting requests"),
                MockElement(role: "text", value: "Too many requests right now — try again in a moment.")
            ])
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .unrecognized(let rawText) = result else {
            return XCTFail("expected .unrecognized, got \(result)")
        }
        XCTAssertEqual(rawText, "Server is temporarily limiting requests")
    }

    func testFindsRevealedDetailTextElsewhereInTreeForThrottleCard() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Server is temporarily limiting requests"),
                MockElement(role: "text", value: "You've hit your session limit · resets 2:20pm")
            ])
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .rateLimited(_, let rawText) = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
        XCTAssertEqual(rawText, "You've hit your session limit · resets 2:20pm")
    }

    func testReturnsNoneWhenNoRateLimitTextPresent() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text", value: "Here's the answer to your question…")
        ])

        XCTAssertEqual(RateLimitDetector.detect(in: tree, now: now), .none)
    }

    /// The new Claude Code CLI banner shows "Usage limit reached" and the
    /// reset date+time as separate sibling elements (no "View details" step).
    /// `bannerKeywords` matches "usage limit reached" but that element's own
    /// text doesn't parse — the nearby-scan must pick up the sibling.
    func testDetectsNewUsageLimitBannerWithSeparateResetElement() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Usage limit reached"),
                MockElement(role: "text", value: "Resets Fri, Jun 12, 12:40 AM")
            ])
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .rateLimited(_, let rawText) = result else {
            return XCTFail("expected .rateLimited, got \(result)")
        }
        XCTAssertEqual(rawText, "Resets Fri, Jun 12, 12:40 AM")
    }

    /// "Approaching weekly usage limit · Resets ..." is an informational
    /// warning shown well before any limit is actually hit — Claude keeps
    /// working normally. `bannerKeywords`'s "usage limit" substring would
    /// otherwise match the first element and the sibling "Resets ..." text
    /// would parse, wrongly scheduling a resume for a window that was never
    /// rate-limited.
    func testIgnoresApproachingUsageLimitWarning() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Approaching weekly usage limit"),
                MockElement(role: "text", value: "Resets Mon, Jun 15, 7:00 PM")
            ])
        ])

        XCTAssertEqual(RateLimitDetector.detect(in: tree, now: now), .none)
    }

    /// A leftover chat message that merely *quotes* or *describes* a past
    /// detection (e.g. "...the deployed app correctly detected a real
    /// "Usage limit reached ... Resets Mon, Jun 15, 7:00 PM" banner...")
    /// contains "usage limit" deep within a long sentence — it must not be
    /// treated as a banner itself, even if a parseable "Resets ..." element
    /// happens to sit nearby (e.g. left over from an unrelated, still-shown
    /// "Approaching weekly usage limit" warning).
    func testIgnoresUsageLimitMentionedInProseFarFromStart() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: ": the deployed app correctly detected a real \"Usage limit reached ... Resets Mon, Jun 15, 7:00 PM\" banner and scheduled a resume with the correct time, with no View-details step involved."),
                MockElement(role: "text", value: "Resets Mon, Jun 15, 7:00 PM")
            ])
        ])

        XCTAssertEqual(RateLimitDetector.detect(in: tree, now: now), .none)
    }

    /// A Claude Code CLI session literally named "rate limit recovery" shows
    /// up in the sidebar as a status label like "Awaiting input rate limit
    /// recovery". The bare "rate limit" keyword matches this label (offset
    /// well under 32, no "approaching"), its own text doesn't parse, and the
    /// generalized nearby-scan then picks up an unrelated "Resets ..." time
    /// left over from a separate "Approaching weekly usage limit" warning —
    /// producing a false rateLimited result even though Claude is working
    /// normally and only the informational warning is showing.
    func testIgnoresSessionNamedRateLimitRecoveryWithNearbyApproachingWarning() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Awaiting input rate limit recovery")
            ]),
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Approaching weekly usage limit"),
                MockElement(role: "text", value: "Resets Mon, Jun 15, 7:00 PM")
            ])
        ])

        XCTAssertEqual(RateLimitDetector.detect(in: tree, now: now), .none)
    }

    // MARK: - Bottommost banner selection

    /// When two throttle-card banners are in the tree (old card above, new card below),
    /// the detector must pick the bottommost one (largest frame.minY).
    func testPicksBottommostBannerWhenMultipleBannersPresent() {
        // Old banner sits higher on screen (smaller Y), has a now-stale expanded detail panel above it.
        // New banner sits lower (larger Y), detail panel not yet revealed.
        // Expect: .unrecognized for the new, lower banner — NOT rateLimited from the old one.
        let tree = MockElement(role: "window", children: [
            // Old (higher on screen, y=100) — its revealed detail panel is nearby but above the new banner
            MockElement(role: "text",
                        value: "You've hit your session limit · resets 2:20pm",
                        frame: CGRect(x: 0, y: 80, width: 400, height: 24)),
            MockElement(role: "text",
                        value: "Server is temporarily limiting requests",
                        frame: CGRect(x: 0, y: 100, width: 400, height: 24)),
            // New (lower on screen, y=600) — no detail panel revealed yet
            MockElement(role: "text",
                        value: "Server is temporarily limiting requests",
                        frame: CGRect(x: 0, y: 600, width: 400, height: 24))
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        // The bottommost banner has no parseable time nearby, so must be .unrecognized
        guard case .unrecognized(let rawText) = result else {
            return XCTFail("expected .unrecognized (new banner has no detail yet), got \(result)")
        }
        XCTAssertEqual(rawText, "Server is temporarily limiting requests")
    }

    /// When the old revealed detail panel sits ABOVE (smaller Y) the new banner,
    /// the position filter must exclude it so the new card correctly appears unparseable.
    func testIgnoresDetailPanelAboveBannerYPosition() {
        // Old panel (y=80) is above the new banner (y=600) — must NOT be used.
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text",
                        value: "You've hit your session limit · resets 2:20pm",
                        frame: CGRect(x: 0, y: 80, width: 400, height: 24)),
            MockElement(role: "text",
                        value: "Server is temporarily limiting requests",
                        frame: CGRect(x: 0, y: 600, width: 400, height: 24))
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .unrecognized = result else {
            return XCTFail("old detail panel above banner must be ignored, got \(result)")
        }
    }

    /// When the detail panel is BELOW the banner (revealed by View details), it must be found.
    func testFindsDetailPanelBelowBanner() {
        // Detail panel (y=650) is below the banner (y=600) — must be included.
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text",
                        value: "Server is temporarily limiting requests",
                        frame: CGRect(x: 0, y: 600, width: 400, height: 24)),
            MockElement(role: "text",
                        value: "You've hit your session limit · resets 2:20pm",
                        frame: CGRect(x: 0, y: 650, width: 400, height: 24))
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .rateLimited(_, let rawText) = result else {
            return XCTFail("detail panel below banner must be found, got \(result)")
        }
        XCTAssertEqual(rawText, "You've hit your session limit · resets 2:20pm")
    }

    /// A stale "Server is temporarily limiting requests" banner element can
    /// remain in the AX tree (e.g., scrolled chat history referencing an
    /// earlier real throttle event) far above an unrelated, currently-showing
    /// "Approaching weekly usage limit · Resets ..." warning. The stale
    /// banner's own text doesn't parse, and nothing parseable sits near it —
    /// the nearby-scan must not reach hundreds of pixels down to grab the
    /// "Approaching ..." warning's "Resets ..." sibling, which describes an
    /// unrelated, non-blocking warning, not this banner.
    func testIgnoresFarAwayResetBelowStaleBanner() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text",
                        value: "Server is temporarily limiting requests",
                        frame: CGRect(x: 0, y: 166, width: 400, height: 24)),
            MockElement(role: "group", children: [
                MockElement(role: "text", value: "Approaching weekly usage limit",
                            frame: CGRect(x: 0, y: 722, width: 400, height: 24)),
                MockElement(role: "text", value: "Resets Mon, Jun 15, 7:00 PM",
                            frame: CGRect(x: 0, y: 722, width: 400, height: 24))
            ])
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .unrecognized(let rawText) = result else {
            return XCTFail("far-away unrelated reset must not be attributed to the stale banner, got \(result)")
        }
        XCTAssertEqual(rawText, "Server is temporarily limiting requests")
    }

    /// A chat message discussing this very detector can quote a phrase like
    /// "Resets Mon, Jun 15, 7:00 PM" deep within a long sentence — e.g. while
    /// explaining a previous false positive. If a short banner-keyword span
    /// (such as a bolded "Server is temporarily limiting requests" run) sits
    /// nearby, the nearby-scan must not treat that long prose as the banner's
    /// reset-time detail: genuine "Resets ..." detail elements are short
    /// labels (≤65 chars in every observed case), while prose merely quoting
    /// one is necessarily much longer.
    func testIgnoresLongProseQuotingResetPhraseNearBanner() {
        let longProse = "This message discusses how the detector handles \"Server is temporarily limiting requests\" banners and the nearby \"Resets Mon, Jun 15, 7:00 PM\" detail text shown in an unrelated warning."
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text",
                        value: "Server is temporarily limiting requests",
                        frame: CGRect(x: 0, y: 100, width: 400, height: 24)),
            MockElement(role: "text", value: longProse,
                        frame: CGRect(x: 0, y: 120, width: 400, height: 60))
        ])

        let result = RateLimitDetector.detect(in: tree, now: now)

        guard case .unrecognized(let rawText) = result else {
            return XCTFail("long prose quoting a reset phrase must not be treated as the banner's detail, got \(result)")
        }
        XCTAssertEqual(rawText, "Server is temporarily limiting requests")
    }

    /// A chat transcript can display syntax-highlighted source code — e.g.
    /// this detector's own test file — where each string literal, including
    /// its surrounding quote marks, is rendered as its own AX text element.
    /// Two adjacent lines like `value: "Usage limit reached"` and
    /// `value: "Resets Fri, Jun 12, 12:40 AM"` then appear as two short,
    /// nearby elements: `"Usage limit reached"` matches bannerKeywords near
    /// offset 0 and doesn't itself parse, while `"Resets Fri, Jun 12, 12:40
    /// AM"` is short enough and near enough to be picked up as its detail —
    /// wrongly producing .rateLimited from two lines of displayed source
    /// code. No genuine banner or detail label is itself wrapped in a
    /// literal quote pair; such text must be ignored entirely.
    /// A chat message asking the user to verify what's on screen can quote a
    /// banner-keyword phrase inline within an otherwise-unquoted question,
    /// e.g. `Do you see a "Server is temporarily limiting requests" / "View
    /// details" banner right now?`. The keyword appears near the start of
    /// the sentence (offset < maxBannerKeywordOffset) and the whole text
    /// isn't quote-wrapped (so `isQuotedText` doesn't exclude it) — but the
    /// keyword phrase itself is immediately bracketed by `"..."`, marking it
    /// as a quotation rather than a genuine banner label.
    func testIgnoresInlineQuotedBannerPhraseWithinQuestion() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text",
                        value: "Do you see a \"Server is temporarily limiting requests\" / \"View details\" banner right now?")
        ])

        XCTAssertEqual(RateLimitDetector.detect(in: tree, now: now), .none)
    }

    func testIgnoresQuotedStringLiteralsFromDisplayedSourceCode() {
        let tree = MockElement(role: "window", children: [
            MockElement(role: "text", value: "\"Usage limit reached\"",
                        frame: CGRect(x: 0, y: 100, width: 200, height: 20)),
            MockElement(role: "text", value: "\"Resets Fri, Jun 12, 12:40 AM\"",
                        frame: CGRect(x: 0, y: 120, width: 200, height: 20))
        ])

        XCTAssertEqual(RateLimitDetector.detect(in: tree, now: now), .none)
    }
}
