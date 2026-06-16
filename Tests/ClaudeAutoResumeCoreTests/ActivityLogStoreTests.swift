import XCTest
@testable import ClaudeAutoResumeCore

final class ActivityLogStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-log-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testAppendAndLoadRoundTrips() throws {
        let store = ActivityLogStore(fileURL: fileURL)
        let event1 = ActivityEvent(timestamp: Date(timeIntervalSince1970: 1000),
                                   windowID: "win-1", windowTitle: nil, kind: .rateLimitDetected, detail: "resets at 3:00 PM")
        let event2 = ActivityEvent(timestamp: Date(timeIntervalSince1970: 2000),
                                   windowID: "win-1", windowTitle: nil, kind: .resumed, detail: "sent 'continue'")

        try store.append(event1)
        try store.append(event2)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded, [event1, event2])
    }

    func testLoadAllOnMissingFileReturnsEmpty() throws {
        let store = ActivityLogStore(fileURL: fileURL)
        XCTAssertEqual(try store.loadAll(), [])
    }

    func testLoadAllSkipsMalformedLines() throws {
        let store = ActivityLogStore(fileURL: fileURL)
        let validEvent = ActivityEvent(timestamp: Date(timeIntervalSince1970: 1000),
                                       windowID: "win-1", windowTitle: nil, kind: .rateLimitDetected, detail: "resets at 3:00 PM")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let validLine = try encoder.encode(validEvent)

        var contents = Data()
        contents.append(validLine)
        contents.append(0x0A)
        contents.append(Data("{not valid json".utf8))
        contents.append(0x0A)
        try contents.write(to: fileURL)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded, [validEvent])
    }

    func testCodableRoundTripIncludesWindowTitle() throws {
        let store = ActivityLogStore(fileURL: fileURL)
        let event = ActivityEvent(timestamp: Date(timeIntervalSince1970: 1000),
                                  windowID: "win-1", windowTitle: "tos player",
                                  kind: .rateLimitDetected, detail: "resets at 3:00 PM")

        try store.append(event)
        let loaded = try store.loadAll()

        XCTAssertEqual(loaded, [event])
        XCTAssertEqual(loaded.first?.windowTitle, "tos player")
    }

    func testLoadAllDecodesEntriesMissingWindowTitleAsNil() throws {
        let json = #"{"timestamp":1000,"windowID":"win-1","kind":"rateLimitDetected","detail":"resets at 3:00 PM"}"#
        try Data((json + "\n").utf8).write(to: fileURL)

        let store = ActivityLogStore(fileURL: fileURL)
        let loaded = try store.loadAll()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.windowTitle)
    }
}
