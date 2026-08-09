import Foundation
import Observation
import VoxglassCore

/// The phone's production relay container (mirrors `ProductionWatchEnvironment` on
/// the watch): owns the preview store, the CloudKit-backed sync, and the phone-side
/// `WatchConnectivityTransport`, and relays the current projection down to the watch
/// after every sync (spec §13.6).
///
/// Watch review events are decoded by the transport and enqueued into the phone's
/// outbox here, so an offline watch action reaches the iPhone exactly once: the outbox
/// is idempotent by event id and the iPhone's fold is idempotent too.
@MainActor
@Observable
public final class PhoneProductionEnvironment {

    public let previewStore: ProductionPreviewStore
    public let sync: PhoneProductionSync
    public let watchTransport: WatchConnectivityTransport
    public let narrationRepository: NarrationProjectRepository

    /// The flow's active recording-remote coordinator, registered while the
    /// record screen is on screen (§14.3). Commands the watch sends are routed
    /// here; `nil` means no session is active, so a command is acknowledged and
    /// dropped by the coordinator's absence.
    public var recordingRemoteCoordinator: RecordingRemoteCoordinator?

    public init(
        previewStore: ProductionPreviewStore? = nil,
        watchTransport: WatchConnectivityTransport? = nil,
        narrationRepository: NarrationProjectRepository = NarrationProjectRepository()
    ) {
        self.previewStore = previewStore ?? ProductionPreviewStore()
        self.narrationRepository = narrationRepository
        self.sync = PhoneProductionSync(previewStore: self.previewStore, narrationRepository: narrationRepository)
        self.watchTransport = watchTransport ?? WatchConnectivityTransport()
        self.watchTransport.onEventReceived = { [weak self] event in
            self?.sync.enqueue(event)
        }
        self.watchTransport.onRecordingRemoteCommandReceived = { [weak self] command in
            guard let self, let coordinator = self.recordingRemoteCoordinator else { return }
            Task { await coordinator.deliver(command) }
        }
        self.watchTransport.onReachabilityChanged = { [weak self] reachable in
            guard reachable else { return }
            Task { await self?.publishToWatch() }
        }
        sync.onProjectionsUpdated = { [weak self] in
            Task { await self?.publishToWatch() }
        }
    }

    /// Relays one live recording-session status frame to the watch (§14.3).
    /// Best-effort: the transport drops it when the session or link is not ready.
    public func pushRecordingRemoteStatus(_ status: RecordingRemoteStatus) async {
        try? await watchTransport.sendRecordingRemoteStatus(status)
    }

    /// Pulls the latest projection and flushes the outbox (spec §14.5 Flow A).
    public func checkForUpdates() async {
        await sync.checkForUpdates()
    }

    /// Derives the local `AudiobookProject` into its projection and applies it
    /// to the preview store and the watch (spec §4.3 / §13.6). The iPhone is the
    /// writer: a freshly saved narration is visible to My Productions and to the
    /// watch immediately, with no CloudKit round-trip.
    public func localPublish(_ project: AudiobookProject) async {
        let projectStore = narrationRepository.store(for: project.id)
        guard let counts = try? await projectStore.counts() else { return }
        let builder = ProjectionBuilder()
        let revision = await narrationRepository.nextProjectionRevision(for: project.id)
        guard let projection = builder.projection(from: project, counts: counts, revision: revision) else { return }
        await previewStore.apply(projection)
        await publishToWatch()
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
