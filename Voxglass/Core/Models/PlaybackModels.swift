import Foundation

struct PlaybackPosition: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var bookID: UUID
    var chapterID: UUID
    var position: TimeInterval
    var duration: TimeInterval?
    var updatedAt: Date
    var isFinished: Bool

    init(
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

struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    var id: UUID?
    var bookID: UUID
    var chapterID: UUID
    var position: TimeInterval
    var note: String?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(
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

struct Playlist: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

struct DownloadRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var bookID: UUID
    var chapterID: UUID?
    var state: DownloadState
    var localURL: URL?
    var bytesDownloaded: Int64
    var bytesExpected: Int64?
    var updatedAt: Date
}

enum DownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case complete
    case failed
}

enum PlaybackMath {
    static func clampedPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = max(0, position)
        guard let duration, duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }
}

