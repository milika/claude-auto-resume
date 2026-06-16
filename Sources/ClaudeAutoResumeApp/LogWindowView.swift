import SwiftUI
import AppKit
import ClaudeAutoResumeCore

struct LogWindowView: View {
    let events: [ActivityEvent]

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        List(events.sorted { $0.timestamp > $1.timestamp }, id: \.timestamp) { event in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.formatter.string(from: event.timestamp))  ·  \(event.windowTitle ?? event.windowID)  ·  \(event.kind.rawValue)")
                    .font(.headline)
                Text(event.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

enum LogWindowFactory {
    /// Builds an `NSWindow` hosting `LogWindowView`, ready to be shown with `makeKeyAndOrderFront`.
    static func makeWindow(events: [ActivityEvent]) -> NSWindow {
        let hosting = NSHostingController(rootView: LogWindowView(events: events))
        let window = NSWindow(contentViewController: hosting)
        window.title = "claude-auto-resume Activity Log"
        window.setContentSize(NSSize(width: 480, height: 320))
        return window
    }
}
