import Foundation
import AVFoundation
import Observation
import UIKit
import VoxglassCore

// MARK: - MyProductionsModel

@MainActor
@Observable
public final class MyProductionsModel {
    public private(set) var summaries: [ProjectSummary] = []
    public private(set) var isLoading = true
    private let store: ProductionPreviewStore

    public init(store: ProductionPreviewStore) {
        self.store = store
    }

    public func load() async {
        isLoading = true
        await store.load()
        summaries = store.summaries()
        isLoading = false
    }
}

// MARK: - ProductionDetailModel

@MainActor
@Observable
public final class ProductionDetailModel {
    public private(set) var projection: SyncProjection?
    public private(set) var flaggedCount = 0
    public private(set) var needsPickupCount = 0
    public private(set) var unapprovedCount = 0

    public let projectID: UUID
    private let store: ProductionPreviewStore

    public init(projectID: UUID, store: ProductionPreviewStore) {
        self.projectID = projectID
        self.store = store
    }

    public func load() async {
        projection = store.projection(id: projectID)
        flaggedCount = store.paragraphs(projectID: projectID, predicate: .flagged).count
        needsPickupCount = store.paragraphs(projectID: projectID, predicate: .needsPickup).count
        unapprovedCount = store.paragraphs(projectID: projectID, predicate: .unapproved).count
    }

    public func chapterRows() -> [ChapterProjection] {
        projection?.chapters ?? []
    }
}

// MARK: - ProductionPlayerModel

/// Review player (mockup `03-production-player`): plays proxy audio paragraph by
/// paragraph and emits review events. Actions are debounced, give haptic feedback,
/// and are queued through the phone outbox (they reach the iPhone exactly once).
@MainActor
@Observable
public final class ProductionPlayerModel: NSObject, AVAudioPlayerDelegate {
    public private(set) var queue: [ParagraphProjection] = []
    public private(set) var currentIndex = 0
    public private(set) var isPlaying = false
    public private(set) var hasLocalAudio = true
    public var autoAdvance = true

    private let projectID: UUID
    private let store: ProductionPreviewStore
    private let sync: PhoneProductionSync
    private var player: AVAudioPlayer?
    private var lastActionAt: Date = .distantPast

    public init(projectID: UUID, store: ProductionPreviewStore, sync: PhoneProductionSync) {
        self.projectID = projectID
        self.store = store
        self.sync = sync
        super.init()
    }

    public var current: ParagraphProjection? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    public func load(_ paragraphs: [ParagraphProjection], startAt index: Int = 0) async {
        queue = paragraphs
        currentIndex = queue.indices.contains(index) ? index : 0
        await loadCurrent()
    }

    public func play() async {
        guard !isPlaying, let current else { return }
        await loadCurrent()
        guard hasLocalAudio else { return }
        player?.play()
        isPlaying = true
    }

    public func pause() async {
        player?.pause()
        isPlaying = false
    }

    public func next() async {
        guard currentIndex + 1 < queue.count else { await pause(); return }
        currentIndex += 1
        await play()
    }

    public func previous() async {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        await play()
    }

    public func skip(by seconds: TimeInterval) async {
        player?.currentTime = min(max((player?.currentTime ?? 0) + seconds, 0), player?.duration ?? 0)
    }

    public func flag() async { await emit(.flag, tag: nil, note: nil) }
    public func approve() async { await emit(.approve, tag: nil, note: nil) }
    public func pickup() async { await emit(.needsPickup, tag: nil, note: nil) }

    public func addNote(text: String, tag: ReviewTag?) async {
        await emit(.addNote, tag: tag, note: text)
    }

    private func emit(_ type: ReviewEventType, tag: ReviewTag?, note: String?) async {
        // Debounce: a double-tap must not emit two events (§18.2.3).
        let now = Date()
        guard now.timeIntervalSince(lastActionAt) > 0.5, let current else { return }
        lastActionAt = now

        let event = ReviewEvent(
            id: UUID(),
            projectID: projectID,
            paragraphID: current.id,
            type: type,
            noteText: note,
            tag: tag,
            device: .iPhone,
            createdAt: now
        )
        sync.enqueue(event)
        haptic(for: type)
    }

    /// Preloads the current paragraph's proxy so `play()` starts instantly; marks
    /// `hasLocalAudio` when the proxy is missing on this device.
    private func loadCurrent() async {
        guard let current else {
            player = nil
            return
        }
        guard let url = store.proxyURL(paragraphID: current.id, projectID: projectID) else {
            hasLocalAudio = false
            player = nil
            return
        }
        hasLocalAudio = true
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
    }

    private func haptic(for type: ReviewEventType) {
        let generator = UINotificationFeedbackGenerator()
        switch type {
        case .approve: generator.notificationOccurred(.success)
        case .needsPickup: generator.notificationOccurred(.warning)
        default: generator.notificationOccurred(.error)
        }
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            if autoAdvance {
                await next()
            }
        }
    }
}

// MARK: - ParagraphListModel

@MainActor
@Observable
public final class ParagraphListModel {
    public private(set) var paragraphs: [ParagraphProjection] = []
    public private(set) var selection: Set<UUID> = []
    public var filter: ReviewPredicate = .flagged

    private let projectID: UUID
    private let store: ProductionPreviewStore

    public init(projectID: UUID, store: ProductionPreviewStore) {
        self.projectID = projectID
        self.store = store
    }

    public func load() async {
        paragraphs = store.paragraphs(projectID: projectID, predicate: filter)
    }

    public func setFilter(_ filter: ReviewPredicate) async {
        self.filter = filter
        await load()
    }

    public func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

// MARK: - ReviewQueueBuilderModel

@MainActor
@Observable
public final class ReviewQueueBuilderModel {
    public private(set) var counts: [ReviewPredicate: Int] = [:]
    public var predicate: ReviewPredicate = .flagged
    public var autoAdvance = true
    public var skipApprovedImmediately = false

    private let projectID: UUID
    private let store: ProductionPreviewStore

    public init(projectID: UUID, store: ProductionPreviewStore) {
        self.projectID = projectID
        self.store = store
    }

    public func load() async {
        let predicates: [ReviewPredicate] = [.flagged, .needsPickup, .unapproved, .unreviewed, .allRecorded]
        var result: [ReviewPredicate: Int] = [:]
        for predicate in predicates {
            result[predicate] = store.paragraphs(projectID: projectID, predicate: predicate).count
        }
        counts = result
    }

    public var resolvedParagraphs: [ParagraphProjection] {
        store.paragraphs(projectID: projectID, predicate: predicate)
    }

    public var totalDuration: TimeInterval {
        resolvedParagraphs.reduce(0) { $0 + $1.duration }
    }

    /// The size estimate for pushing the resolved queue to the watch (§18.2.5):
    /// the on-device proxies, not the lossless masters. The watch enforces its
    /// own 200 MB cap with least-recently-queued eviction.
    public var watchQueueEstimate: (paragraphCount: Int, totalBytes: Int64) {
        let paragraphs = resolvedParagraphs
        var bytes: Int64 = 0
        for paragraph in paragraphs {
            guard let url = store.proxyURL(paragraphID: paragraph.id, projectID: projectID),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            bytes += Int64(size)
        }
        return (paragraphs.count, bytes)
    }

    /// Pushes the resolved queue's proxies to the watch through the transport.
    /// Returns the number of paragraphs actually queued (those with a proxy
    /// already on device).
    public func downloadToWatch(using transport: any WatchTransport) async throws -> Int {
        let paragraphs = resolvedParagraphs
        var items: [WatchAudioItem] = []
        for paragraph in paragraphs {
            guard let url = store.proxyURL(paragraphID: paragraph.id, projectID: projectID) else { continue }
            let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            items.append(WatchAudioItem(
                paragraphID: paragraph.id,
                sha256: paragraph.proxySourceSHA ?? "",
                byteCount: byteCount,
                fileURL: url
            ))
        }
        try await transport.sendAudio(items)
        return items.count
    }
}

// MARK: - ReviewNoteModel

@MainActor
@Observable
public final class ReviewNoteModel {
    public var text = ""
    public var tag: ReviewTag?

    public init() {}
}

// MARK: - ProductionSyncModel

@MainActor
@Observable
public final class ProductionSyncModel {
    public private(set) var accountStatus: SyncAccountStatus = .unavailable
    public private(set) var lastReceivedRevision: Int?
    public private(set) var lastSyncDate: Date?
    public private(set) var syncError: String?
    public private(set) var pendingOutboxCount = 0
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var watchQueueCount = 0

    private let sync: PhoneProductionSync
    private let store: ProductionPreviewStore

    public init(sync: PhoneProductionSync, store: ProductionPreviewStore) {
        self.sync = sync
        self.store = store
    }

    public func load() async {
        accountStatus = sync.accountStatus
        lastReceivedRevision = sync.lastReceivedRevision
        lastSyncDate = sync.lastSyncDate
        syncError = sync.syncError
        pendingOutboxCount = sync.pendingOutboxCount
        downloadedBytes = store.downloadedBytes
    }

    public func checkForUpdates() async {
        await sync.checkForUpdates()
        await load()
    }

    public func removeDownloadedAudio() async {
        for summary in store.summaries() {
            await store.removeDownloadedAudio(projectID: summary.id)
        }
        await load()
    }
}
