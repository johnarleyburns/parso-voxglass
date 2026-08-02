import Foundation
import Observation
import VoxglassCore

/// The phone's production relay container (mirrors `ProductionWatchEnvironment` on
/// the watch): owns the preview store, the CloudKit-backed sync, and the phone-side
/// `WatchConnectivityTransport`, and relays the current projection down to the watch
/// after every sync (spec §13.6).
///
/// Watch review events are decoded by the transport and enqueued into the phone's
/// outbox here, so an offline watch action reaches the Mac exactly once: the outbox
/// is idempotent by event id and the Mac's fold is idempotent too.
@MainActor
@Observable
public final class PhoneProductionEnvironment {

    public let previewStore: ProductionPreviewStore
    public let sync: PhoneProductionSync
    public let watchTransport: WatchConnectivityTransport

    public init(
        previewStore: ProductionPreviewStore? = nil,
        watchTransport: WatchConnectivityTransport? = nil
    ) {
        self.previewStore = previewStore ?? ProductionPreviewStore()
        self.sync = PhoneProductionSync(previewStore: self.previewStore)
        self.watchTransport = watchTransport ?? WatchConnectivityTransport()
        self.watchTransport.onEventReceived = { [weak self] event in
            self?.sync.enqueue(event)
        }
        self.watchTransport.onReachabilityChanged = { [weak self] reachable in
            guard reachable else { return }
            Task { await self?.publishToWatch() }
        }
        sync.onProjectionsUpdated = { [weak self] in
            Task { await self?.publishToWatch() }
        }
    }

    /// Pulls the latest projection and flushes the outbox (spec §14.5 Flow A).
    public func checkForUpdates() async {
        await sync.checkForUpdates()
    }

    /// Pushes summaries for every project and the current flagged review queue plus
    /// its proxy audio down to the watch (§13.6 rules 1–3). The most recently
    /// modified project with a flagged queue becomes the watch's active queue.
    public func publishToWatch() async {
        let summaries = previewStore.summaries()
        guard !summaries.isEmpty else { return }
        try? await watchTransport.sendSummaries(summaries)

        let candidates = summaries.filter { flaggedParagraphs(for: $0.id).count > 0 }
        guard let target = candidates.max(by: { $0.modifiedAt < $1.modifiedAt }) else { return }
        guard let projection = previewStore.projection(id: target.id) else { return }

        let flagged = flaggedParagraphs(for: target.id)
        let payload = ResolvedQueuePayload(
            projectID: target.id,
            projectTitle: target.title,
            queueLabel: "Flagged",
            paragraphIDs: flagged.map(\.id),
            texts: dictionary(flagged.compactMap { p in p.text.map { (p.id, $0) } }),
            notes: dictionary(flagged.compactMap { p in p.latestNoteText.map { (p.id, $0) } }),
            durations: dictionary(flagged.compactMap { p in p.duration > 0 ? (p.id, p.duration) : nil }),
            chapterLabels: dictionary(flagged.compactMap { p in chapterLabel(for: p, in: projection) }),
            tags: dictionary(flagged.compactMap { p in p.latestNoteTag.map { (p.id, $0) } }),
            autoAdvance: true,
            revision: projection.revision
        )
        try? await watchTransport.sendActiveQueue(payload)

        let pinned = Set(projection.watchPinnedParagraphIDs)
        let wanted = pinned.isEmpty ? Set(flagged.map(\.id)) : pinned
        let audio: [WatchAudioItem] = flagged.compactMap { paragraph in
            guard wanted.contains(paragraph.id),
                  let url = previewStore.proxyURL(paragraphID: paragraph.id, projectID: target.id) else { return nil }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return WatchAudioItem(
                paragraphID: paragraph.id,
                sha256: paragraph.proxySourceSHA ?? "",
                byteCount: bytes,
                fileURL: url
            )
        }
        try? await watchTransport.sendAudio(audio)
    }

    // MARK: - Internals

    private func flaggedParagraphs(for projectID: UUID) -> [ParagraphProjection] {
        previewStore.paragraphs(projectID: projectID, predicate: .flagged)
    }

    private func chapterLabel(for paragraph: ParagraphProjection, in projection: SyncProjection) -> (UUID, String)? {
        guard let chapter = projection.chapters.first(where: { $0.id == paragraph.chapterID }) else { return nil }
        return (paragraph.id, "Chapter \(chapter.ordinal + 1) · ¶ \(paragraph.globalOrdinal + 1)")
    }

    private func dictionary<Key: Hashable, Value>(_ pairs: [(Key, Value)]) -> [Key: Value] {
        Dictionary(uniqueKeysWithValues: pairs)
    }
}
