import Foundation
import VoxglassWatchProtocol

public enum WatchPlaybackSourceKind: String, Codable, Equatable, Sendable {
    case downloaded
    case stream
}

public enum WatchPlaybackPhase: Codable, Equatable, Sendable {
    case idle
    case preparing
    case waitingForOutput
    case buffering
    case playing
    case paused
    case ended
    case failed(String)
}

public struct WatchPlaybackSnapshot: Codable, Equatable, Sendable {
    public var bookID: WatchBookID?
    public var chapterID: WatchChapterID?
    public var chapterIndex: Int
    public var chapterCount: Int
    public var position: TimeInterval
    public var duration: TimeInterval
    public var rate: Double
    public var phase: WatchPlaybackPhase
    public var sourceKind: WatchPlaybackSourceKind?
    public var eventToken: Int

    public init(
        bookID: WatchBookID? = nil,
        chapterID: WatchChapterID? = nil,
        chapterIndex: Int = 0,
        chapterCount: Int = 0,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        rate: Double = 1,
        phase: WatchPlaybackPhase = .idle,
        sourceKind: WatchPlaybackSourceKind? = nil,
        eventToken: Int = 0
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.position = Self.clean(position)
        self.duration = Self.clean(duration)
        self.rate = rate.isFinite && rate > 0 ? rate : 1
        self.phase = phase
        self.sourceKind = sourceKind
        self.eventToken = eventToken
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    public var canGoPrevious: Bool { chapterCount > 0 && chapterIndex > 0 }
    public var canGoNext: Bool { chapterCount > 0 && chapterIndex + 1 < chapterCount }
    public var isActuallyPlaying: Bool { phase == .playing }

    public var statusText: String {
        switch phase {
        case .idle: "Nothing playing"
        case .preparing: "Preparing…"
        case .waitingForOutput: "Waiting for headphones"
        case .buffering: "Buffering…"
        case .playing: "Playing"
        case .paused: "Paused"
        case .ended: "Finished"
        case .failed(let message): message
        }
    }

    private static func clean(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

public struct WatchResolvedPlaybackSource: Equatable, Sendable {
    public var url: URL
    public var kind: WatchPlaybackSourceKind
    public var assetOffset: TimeInterval

    public init(url: URL, kind: WatchPlaybackSourceKind, assetOffset: TimeInterval) {
        self.url = url
        self.kind = kind
        self.assetOffset = assetOffset.isFinite ? max(0, assetOffset) : 0
    }
}

public enum WatchPlaybackResolutionError: Error, Equatable, Sendable {
    case invalidFilename
    case chapterUnavailable
}

public enum WatchPlaybackSourceResolver {
    public static func resolve(
        bookID: WatchBookID,
        chapter: WatchChapterDTO,
        downloadsRoot: URL,
        allowsStreaming: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> WatchResolvedPlaybackSource {
        let filename = chapter.durableFilename
        guard !filename.isEmpty,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains("/") && !filename.contains("\\") else {
            throw WatchPlaybackResolutionError.invalidFilename
        }

        let local = downloadsRoot
            .appendingPathComponent(bookID.rawValue, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        if fileExists(local) {
            return WatchResolvedPlaybackSource(url: local, kind: .downloaded, assetOffset: chapter.startTime)
        }

        if allowsStreaming,
           let remote = chapter.approvedStreamURL,
           remote.scheme?.lowercased() == "https",
           remote.user == nil,
           remote.password == nil,
           remote.host != nil {
            return WatchResolvedPlaybackSource(url: remote, kind: .stream, assetOffset: chapter.startTime)
        }
        throw WatchPlaybackResolutionError.chapterUnavailable
    }
}

public enum WatchPlaybackEvent: Equatable, Sendable {
    case waitingForOutput
    case buffering
    case playing
    case paused
    case time(position: TimeInterval, duration: TimeInterval)
    case interruption
    case routeLost
    case failed(String)
    case ended
}

public enum WatchPlaybackReducer {
    public static func preparing(
        bookID: WatchBookID,
        chapter: WatchChapterDTO,
        chapterCount: Int,
        position: TimeInterval,
        token: Int
    ) -> WatchPlaybackSnapshot {
        WatchPlaybackSnapshot(
            bookID: bookID,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            chapterCount: chapterCount,
            position: position,
            duration: chapter.duration,
            phase: .preparing,
            eventToken: token
        )
    }

    public static func reduce(
        _ current: WatchPlaybackSnapshot,
        event: WatchPlaybackEvent,
        token: Int
    ) -> WatchPlaybackSnapshot {
        guard token == current.eventToken else { return current }
        var next = current
        switch event {
        case .waitingForOutput:
            next.phase = .waitingForOutput
        case .buffering:
            next.phase = .buffering
        case .playing:
            next.phase = .playing
        case .paused, .interruption:
            next.phase = .paused
        case .routeLost:
            next.phase = .failed("Connect Bluetooth headphones, then try again.")
        case .failed(let message):
            next.phase = .failed(message)
        case .ended:
            next.position = next.duration
            next.phase = .ended
        case .time(let position, let duration):
            next.position = clean(position)
            if duration.isFinite && duration > 0 { next.duration = duration }
        }
        return next
    }

    private static func clean(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

public actor WatchPlaybackPositionStore {
    private struct Values: Codable {
        var positions: [String: Double] = [:]
    }

    private let url: URL
    private var values: Values

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            values = decoded
        } else {
            values = Values()
        }
    }

    public func position(bookID: WatchBookID, chapterID: WatchChapterID) -> TimeInterval {
        values.positions[key(bookID: bookID, chapterID: chapterID)] ?? 0
    }

    public func save(_ position: TimeInterval, bookID: WatchBookID, chapterID: WatchChapterID) throws {
        values.positions[key(bookID: bookID, chapterID: chapterID)] = position.isFinite ? max(0, position) : 0
        try persist()
    }

    public func remove(bookID: WatchBookID) throws {
        let prefix = "\(bookID.rawValue)|"
        values.positions = values.positions.filter { !$0.key.hasPrefix(prefix) }
        try persist()
    }

    private func key(bookID: WatchBookID, chapterID: WatchChapterID) -> String {
        "\(bookID.rawValue)|\(chapterID.rawValue)"
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
}
