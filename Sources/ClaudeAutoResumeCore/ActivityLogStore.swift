import Foundation

/// Append-only, newline-delimited-JSON log of detection and resume events.
public final class ActivityLogStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .secondsSince1970
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .secondsSince1970
    }

    public func append(_ event: ActivityEvent) throws {
        let data = try encoder.encode(event)
        var line = data
        line.append(0x0A) // newline

        // Open (creating if necessary) without truncating, so a concurrent
        // create/delete between an existence check and the write can't destroy
        // existing log contents or cause "no such file" errors. O_CREAT without
        // O_TRUNC is a no-op on an existing file's contents.
        let fd = open(fileURL.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: fileURL.path
            ])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line)
    }

    public func loadAll() throws -> [ActivityEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return contents
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ActivityEvent.self, from: Data($0.utf8)) }
    }
}
