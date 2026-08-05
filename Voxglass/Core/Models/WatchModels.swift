import Foundation

/// On-watch book storage state machine. Pure model, host-testable.
public enum WatchTransferState: Equatable, Sendable, Codable {
    case notAvailable
    case queued
    case waitingForPhone
    case transferring(progress: Double)
    case available
    case failed

    private enum CodingKeys: String, CodingKey {
        case kind
        case progress
    }

    private enum Kind: String, Codable {
        case notAvailable
        case queued
        case waitingForPhone
        case transferring
        case available
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notAvailable:
            self = .notAvailable
        case .queued:
            self = .queued
        case .waitingForPhone:
            self = .waitingForPhone
        case .transferring:
            self = .transferring(progress: try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0)
        case .available:
            self = .available
        case .failed:
            self = .failed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notAvailable:
            try container.encode(Kind.notAvailable, forKey: .kind)
        case .queued:
            try container.encode(Kind.queued, forKey: .kind)
        case .waitingForPhone:
            try container.encode(Kind.waitingForPhone, forKey: .kind)
        case .transferring(let progress):
            try container.encode(Kind.transferring, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .available:
            try container.encode(Kind.available, forKey: .kind)
        case .failed:
            try container.encode(Kind.failed, forKey: .kind)
        }
    }

    public var progressFraction: Double? {
        if case .transferring(let progress) = self {
            return progress
        }
        return nil
    }
}

/// Snapshot of a single chapter's watch-local storage state.
public struct WatchChapterStorageInfo: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let chapterIndex: Int
    public let state: WatchTransferState
    public let byteCount: Int64
    public let bytesExpected: Int64?

    public init(
        id: UUID,
        chapterIndex: Int,
        state: WatchTransferState,
        byteCount: Int64 = 0,
        bytesExpected: Int64? = nil
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.state = state
        self.byteCount = byteCount
        self.bytesExpected = bytesExpected
    }
}

/// Snapshot of a book's on-watch storage.
public struct WatchBookStorageInfo: Equatable, Sendable, Codable {
    public let state: WatchTransferState
    public let byteCount: Int64
    public let chapterCount: Int
    public let completeChapterCount: Int
    public let totalChapterCount: Int
    public let chapters: [WatchChapterStorageInfo]

    public init(
        state: WatchTransferState,
        byteCount: Int64,
        chapterCount: Int,
        completeChapterCount: Int,
        totalChapterCount: Int = 0,
        chapters: [WatchChapterStorageInfo] = []
    ) {
        self.state = state
        self.byteCount = byteCount
        self.chapterCount = chapterCount
        self.completeChapterCount = completeChapterCount
        self.totalChapterCount = totalChapterCount
        self.chapters = chapters
    }

    public static let notAvailable = WatchBookStorageInfo(
        state: .notAvailable,
        byteCount: 0,
        chapterCount: 0,
        completeChapterCount: 0,
        totalChapterCount: 0,
        chapters: []
    )

    public var phoneLibraryStatusText: String? {
        let total = max(totalChapterCount, chapters.count, completeChapterCount)
        switch state {
        case .available:
            return "Downloaded on Watch"
        case .transferring(let progress):
            return "Downloading to Watch \(Int(progress * 100))%"
        case .queued:
            guard completeChapterCount > 0 else { return "Queued for Watch" }
            return "\(completeChapterCount)/\(max(total, 1)) chapters on Watch"
        case .waitingForPhone:
            return "Watch download waiting"
        case .failed:
            return "Watch download failed"
        case .notAvailable:
            return nil
        }
    }
}

/// The watch's storage report sent back to the iPhone. This is deliberately
/// separate from the iPhone library snapshot: the watch owns watch-local files.
public struct WatchStorageSnapshot: Equatable, Sendable, Codable {
    public let books: [UUID: WatchBookStorageInfo]
    public let generatedAt: Date

    public init(
        books: [UUID: WatchBookStorageInfo],
        generatedAt: Date = Date()
    ) {
        self.books = books
        self.generatedAt = generatedAt
    }

    public func storageInfo(for bookID: UUID) -> WatchBookStorageInfo? {
        books[bookID]
    }
}

/// Watch storage policy constants. Pure, host-testable.
public enum WatchStoragePolicy {
    public static let maxBooks = 5
    public static let maxBytes: Int64 = 2_000_000_000 // 2 GB

    public static func remainingBookSlots(currentCount: Int) -> Int {
        max(0, maxBooks - currentCount)
    }

    public static func remainingBytes(currentBytes: Int64) -> Int64 {
        max(0, maxBytes - currentBytes)
    }
}

/// Timestamp-based eviction order: older last-played entries evicted first.
/// Never evicts the currently-playing book.
public enum WatchEvictionPolicy {
    public static func evictionOrder(
        books: [(id: UUID, lastPlayedAt: Date)],
        currentBookID: UUID?
    ) -> [UUID] {
        books
            .filter { $0.id != currentBookID }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }
            .map(\.id)
    }
}

/// Time formatting for watch display. Pure, host-testable.
public enum WatchTimeFormat {
    public static func duration(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hrs > 0 {
            return "\(hrs)h \(mins)m"
        }
        return "\(mins)m"
    }

    public static func time(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    /// Formats bytes for display on small screens.
    public static func bytes(_ count: Int64) -> String {
        if count < 1024 { return "\(count) B" }
        let kb = Double(count) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.1f GB", gb)
    }
}

/// Adjacent-chapter navigation over a book's chapters in natural (play) order.
/// Pure, host-testable — used by the watch "next/previous chapter" controls.
public enum WatchChapterNavigation {
    public static func next(after chapterID: UUID, in chapters: [Chapter]) -> Chapter? {
        let sorted = chapters.naturallySorted()
        guard let idx = sorted.firstIndex(where: { $0.id == chapterID }),
              idx + 1 < sorted.count else { return nil }
        return sorted[idx + 1]
    }

    public static func previous(before chapterID: UUID, in chapters: [Chapter]) -> Chapter? {
        let sorted = chapters.naturallySorted()
        guard let idx = sorted.firstIndex(where: { $0.id == chapterID }),
              idx - 1 >= 0 else { return nil }
        return sorted[idx - 1]
    }
}

/// Canonical local-cache identity for a chapter's audio on the watch. Thin shim
/// over `ChapterAudioIdentity` so the watch store, the phone→watch transfer, and
/// the phone downloader all agree on one key per chapter (INV-B). Every
/// watch-cache read/write MUST key on this so a file downloaded under one URL
/// variant is still found later. Pure, host-testable.
public enum WatchChapterCache {
    public static func canonicalURL(for chapter: Chapter) -> URL? {
        ChapterAudioIdentity.canonicalURL(for: chapter)
    }

    public static func key(for chapter: Chapter) -> String? {
        ChapterAudioIdentity.cacheKey(for: chapter)
    }
}

/// Transfer state machine: determines the visible state for a give set of inputs.
/// Pure, host-testable.
public enum WatchTransferStateResolver {

    /// Resolves the visible transfer state from the current facts.
    /// - Parameters:
    ///   - isDownloaded: all cached chapter bytes are complete
    ///   - isQueued: a download task exists but hasn't started
    ///   - isTransferring: bytes are actively flowing
    ///   - progress: 0...1 fraction complete
    ///   - isFailed: a prior attempt failed
    ///   - isPhoneReachable: WCSession is reachable
    ///   - needsPhoneTransfer: download requires phone as transport
    public static func resolve(
        isDownloaded: Bool,
        isQueued: Bool,
        isTransferring: Bool,
        progress: Double,
        isFailed: Bool,
        isPhoneReachable: Bool,
        needsPhoneTransfer: Bool
    ) -> WatchTransferState {
        if isDownloaded { return .available }
        if isFailed { return .failed }
        if isTransferring { return .transferring(progress: progress) }
        if needsPhoneTransfer && !isPhoneReachable { return .waitingForPhone }
        if isQueued { return .queued }
        return .notAvailable
    }
}
