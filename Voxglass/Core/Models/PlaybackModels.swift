import Foundation

public struct PlaybackPosition: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bookID: UUID
    public var chapterID: UUID
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var updatedAt: Date
    public var isFinished: Bool

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        position: TimeInterval,
        duration: TimeInterval? = nil,
        updatedAt: Date = Date(),
        isFinished: Bool = false
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.position = PlaybackMath.clampedPosition(position, duration: duration)
        self.duration = duration
        self.updatedAt = updatedAt
        self.isFinished = isFinished
    }
}

public struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID?
    public var bookID: UUID
    public var chapterID: UUID
    public var position: TimeInterval
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID? = nil,
        bookID: UUID,
        chapterID: UUID,
        position: TimeInterval,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeleted: Bool = false
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.position = position
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public struct Playlist: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DownloadRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bookID: UUID
    public var chapterID: UUID?
    public var state: DownloadState
    public var localURL: URL?
    public var bytesDownloaded: Int64
    public var bytesExpected: Int64?
    public var updatedAt: Date
}

public enum DownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case complete
    case failed
}

public enum PlaybackMath {
    public static func clampedPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = max(0, position)
        guard let duration, duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }
}

