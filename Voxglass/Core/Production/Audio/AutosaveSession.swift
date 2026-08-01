import Foundation

/// The `Autosave/session.json` payload (spec §7.7). Written before the engine
/// starts recording, deleted on normal stop. Its presence at package-open time
/// means a take from a crashed session can be recovered.
public struct AutosaveSession: Codable, Sendable, Equatable {
    public struct Format: Codable, Sendable, Equatable {
        public var sampleRate: Double
        public var channels: Int
        public var bitDepth: Int

        public init(sampleRate: Double, channels: Int, bitDepth: Int) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitDepth = bitDepth
        }
    }

    public var takeID: UUID
    public var paragraphID: UUID
    public var chapterID: UUID?
    public var filePath: String
    public var format: Format
    public var startedAt: TimeInterval
    public var appVersion: String

    public init(
        takeID: UUID,
        paragraphID: UUID,
        chapterID: UUID?,
        filePath: String,
        format: Format,
        startedAt: TimeInterval,
        appVersion: String
    ) {
        self.takeID = takeID
        self.paragraphID = paragraphID
        self.chapterID = chapterID
        self.filePath = filePath
        self.format = format
        self.startedAt = startedAt
        self.appVersion = appVersion
    }
}

public enum AutosaveSessionFile {
    public static func read(from url: URL) throws -> AutosaveSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AutosaveSession.self, from: data)
    }

    public static func write(_ session: AutosaveSession, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: url, options: .atomic)
    }

    public static func delete(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
