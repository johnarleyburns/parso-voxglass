import Foundation

/// Everything the phone relays for one review queue so the watch can run hands-free
/// review without touching iCloud. `paragraphIDs` is the resolved queue order; the
/// parallel dictionaries key off paragraph ID.
public struct ResolvedQueuePayload: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var projectTitle: String
    public var queueLabel: String
    public var paragraphIDs: [UUID]
    public var texts: [UUID: String]
    public var notes: [UUID: String]
    public var durations: [UUID: TimeInterval]
    public var chapterLabels: [UUID: String]
    public var tags: [UUID: ReviewTag]
    public var autoAdvance: Bool
    public var revision: Int

    public init(
        projectID: UUID,
        projectTitle: String,
        queueLabel: String,
        paragraphIDs: [UUID] = [],
        texts: [UUID: String] = [:],
        notes: [UUID: String] = [:],
        durations: [UUID: TimeInterval] = [:],
        chapterLabels: [UUID: String] = [:],
        tags: [UUID: ReviewTag] = [:],
        autoAdvance: Bool = true,
        revision: Int = 0
    ) {
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.queueLabel = queueLabel
        self.paragraphIDs = paragraphIDs
        self.texts = texts
        self.notes = notes
        self.durations = durations
        self.chapterLabels = chapterLabels
        self.tags = tags
        self.autoAdvance = autoAdvance
        self.revision = revision
    }
}

/// One paragraph's audio transferred to the watch as a file. `fileURL` is set only
/// on the sending side; the receiving side keys by `paragraphID` and stores the file
/// under its own audio store.
public struct WatchAudioItem: Codable, Sendable, Equatable {
    public var paragraphID: UUID
    public var sha256: String
    public var byteCount: Int
    public var fileURL: URL?

    public init(
        paragraphID: UUID,
        sha256: String = "",
        byteCount: Int = 0,
        fileURL: URL? = nil
    ) {
        self.paragraphID = paragraphID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fileURL = fileURL
    }
}

/// WatchConnectivity action namespace for the production relay. Kept in Core so the
/// phone and watch sides share one vocabulary (mirrors `WatchPhoneAction`).
public enum ProductionTransportAction {
    public static let sendSummaries = "production.sendSummaries"
    public static let sendActiveQueue = "production.sendActiveQueue"
    public static let sendAudio = "production.sendAudio"
    public static let sendArtwork = "production.sendArtwork"
    public static let reviewEvent = "production.reviewEvent"
    public static let requestRefresh = "production.requestRefresh"
}

/// Resolves which queue items the watch should have audio for, per spec §13.6 rule 2:
/// the current and next items are transferred eagerly; everything is transferred only
/// when "Prepare Offline Queue" was used.
public struct WatchQueueAudioResolver: Sendable {

    public enum Mode: Sendable, Equatable {
        case streaming
        case offlineQueuePrepared
    }

    public init() {}

    public func eagerParagraphIDs(
        queue: [UUID],
        currentIndex: Int,
        mode: Mode
    ) -> [UUID] {
        guard !queue.isEmpty else { return [] }
        if mode == .offlineQueuePrepared { return queue }

        let boundedIndex = min(max(currentIndex, 0), queue.count - 1)
        var result: [UUID] = []
        if boundedIndex < queue.count { result.append(queue[boundedIndex]) }
        if boundedIndex + 1 < queue.count { result.append(queue[boundedIndex + 1]) }
        return result
    }
}
