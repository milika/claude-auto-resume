# ClaudeAutoResume

> A tiny macOS menu-bar app that keeps your Claude conversations going through rate limits — no babysitting.

If you've ever been deep in a Claude session, hit a usage limit, and had to stop what you were doing to come back later and type `continue` — this is for you.

## What it does

- 🔍 **Detects rate-limit banners** in both **Claude Desktop** windows and **Claude Code** running in Terminal.app
- ⏱️ **Reads the reset time** Claude itself reports and waits precisely for it
- ↩️ **Resumes automatically** — types `continue` and sends it for you
- 🪟 **Tracks multiple conversations** independently, each on its own timer
- 📋 **Keeps an activity log** so you can see exactly what it detected and did
- 🚀 **Runs quietly in the menu bar** — launches at login, gets out of your way

## Download

Get the latest DMG from the [**Releases** page](https://github.com/milika/claude-auto-resume/releases/latest).

1. Open the DMG and drag **ClaudeAutoResume.app** into your **Applications** folder.
2. Launch it. macOS will prompt you to grant **Accessibility** permission — the app needs this to read Claude's windows and type into them. Open System Settings → Privacy & Security → Accessibility and toggle ClaudeAutoResume on.
3. The app adds itself to Login Items automatically. It'll be running in your menu bar from now on.

> **First-launch note:** until the project gets an Apple Developer ID for notarization, downloaded builds will trigger a Gatekeeper warning. Workaround: right-click **ClaudeAutoResume.app** in Applications → **Open** → **Open** again in the dialog, or run `xattr -dr com.apple.quarantine /Applications/ClaudeAutoResume.app` in Terminal once.

## How it works

ClaudeAutoResume watches your Claude windows (Desktop or Terminal) every few seconds via macOS's Accessibility API. When it sees a rate-limit banner, it:

1. Parses the reset time Claude reports (e.g. *"resets at 3:00 PM"* or *"try again in 2 hours"*)
2. Schedules a one-shot timer for that exact moment
3. Shows the countdown in your menu bar
4. When the timer fires: brings the right window to the front, types `continue`, sends it
5. Logs the whole sequence — see **Show Activity Log…** in the menu-bar dropdown

Each tracked window has its own independent timer, so multiple stalled conversations all resume correctly even if they reset at different times.

## Privacy

ClaudeAutoResume has **no network access**. It reads text from your Claude windows, types `continue` into them, and writes to a local activity log. Nothing leaves your machine. The app is open source — audit the code yourself in [`Sources/`](Sources).

## Building from source

Swift Package Manager is the canonical build path:

```sh
git clone https://github.com/milika/claude-auto-resume.git
cd claude-auto-resume
swift test              # run the test suite
swift build -c release  # build ClaudeAutoResumeApp
```

The Xcode project (`ClaudeAutoResume.xcodeproj`) is also available for those who prefer it. Tests live in `Tests/`.

## Contributing

Issues and PRs welcome! If you're thinking of a larger change, open an issue first to discuss.

## Support this project

ClaudeAutoResume is free and MIT-licensed. If it saves you time, a small one-time donation helps justify the time spent maintaining it:

👉 **[Support on Ko-fi](https://ko-fi.com/milikadelic)** 👈

## License

[MIT](LICENSE) © 2026 Milika Delic
