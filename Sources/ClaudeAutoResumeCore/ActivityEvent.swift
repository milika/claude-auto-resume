import Foundation

public struct ActivityEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        case rateLimitDetected
        case resumeScheduled
        case resumed
        case windowClosed
        case unrecognizedState
        case permissionLost
        case resumeCancelled
        case suppressionCleared
        case suppressionExpired
        case resumeSuppressed
        case resumeGaveUp
    }

    public let timestamp: Date
    public let windowID: String
    /// Human-readable label for `windowID` at the moment the event was
    /// logged — `nil` when the window had no AX title (or, for entries
    /// written before this field existed, simply absent from the JSON;
    /// `Decodable`'s synthesized conformance treats a missing key on an
    /// `Optional` stored property as `nil`, so old `.jsonl` history keeps
    /// loading with no migration).
    public let windowTitle: String?
    public let kind: Kind
    public let detail: String

    public init(timestamp: Date, windowID: String, windowTitle: String?, kind: Kind, detail: String) {
        self.timestamp = timestamp
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.kind = kind
        self.detail = detail
    }
}
