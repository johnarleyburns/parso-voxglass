import Foundation

/// On-watch book storage state machine. Pure model, host-testable.
public enum WatchTransferState: Equatable, Sendable {
    case notAvailable
    case queued
    case waitingForPhone
    case transferring(progress: Double)
    case available
    case failed
}

/// Snapshot of a book's on-watch storage.
public struct WatchBookStorageInfo: Equatable, Sendable {
    public let state: WatchTransferState
    public let byteCount: Int64
    public let chapterCount: Int
    public let completeChapterCount: Int

    public init(
        state: WatchTransferState,
        byteCount: Int64,
        chapterCount: Int,
        completeChapterCount: Int
    ) {
        self.state = state
        self.byteCount = byteCount
        self.chapterCount = chapterCount
        self.completeChapterCount = completeChapterCount
    }

    public static let notAvailable = WatchBookStorageInfo(
        state: .notAvailable,
        byteCount: 0,
        chapterCount: 0,
        completeChapterCount: 0
    )
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
