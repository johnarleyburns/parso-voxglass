import Foundation
import Observation
import VoxglassCore

@MainActor
protocol NarrationLibraryImporting: AnyObject {
    func importNarration(directory: URL, title: String, files: [LocalAudioImport]) async throws -> BookWithChapters
    func play(_ book: BookWithChapters) async
}

@MainActor
final class NarrationLibraryImporter: NarrationLibraryImporting {
    private let services: AppServices

    init(services: AppServices) { self.services = services }

    func importNarration(directory: URL, title: String, files: [LocalAudioImport]) async throws -> BookWithChapters {
        let book = try await services.libraryRepository.importLocalFolder(folderURL: directory, folderName: title, files: files)
        await services.libraryStore.refresh()
        return book
    }

    func play(_ book: BookWithChapters) async {
        await services.playbackCoordinator.play(book)
    }
}

/// The phone's discovery composition root (NARRATION_NEEDS_SPEC §11.1): owns
/// the ladder aggregator (all seven rungs), the last-good cache, the fetcher,
/// the deterministic clock, and the My Narrations store. The surface is always
/// full: the bundled seed floors it, live rungs enrich it, failures vanish.
///
/// My Narrations are `AudiobookProject`s in the SQLite production store (spec
/// §4.3). Saving a narration also projects it into `ProductionPreviewStore` and
/// relays it to the watch through `phoneProduction`.
@MainActor
@Observable
public final class DiscoveryEnvironment {
    public let aggregator: LadderNeedsAggregator
    public let repository: NarrationProjectRepository
    public let clock: any Clock

    public private(set) var needs: [NarrationNeed] = []
    public private(set) var featured: NarrationNeed?
    public private(set) var freshness: Freshness = .seedOnly
    public private(set) var myNarrations: [AudiobookProject] = []
    public private(set) var isRefreshing = false

    /// The phone's production relay, set once at bootstrap so a narration saved
    /// by the flow is projected into `ProductionPreviewStore` and pushed to the
    /// watch (spec §4.3 / §13.6).
    public var phoneProduction: PhoneProductionEnvironment?
    public var library: (any NarrationLibraryImporting)?

    public var lastSnapshot: NeedsSnapshot?

    public init(
        sources: [any NeedsSource] = DiscoveryEnvironment.defaultSources(),
        cache: any NeedsCaching = DiscoveryEnvironment.defaultCache(),
        fetcher: any HTTPFetching = URLSessionFetcher(),
        clock: any Clock = SystemClock(),
        repository: NarrationProjectRepository = NarrationProjectRepository()
    ) {
        self.aggregator = LadderNeedsAggregator(sources: sources, cache: cache, fetcher: fetcher, clock: clock)
        self.repository = repository
        self.clock = clock
        #if DEBUG
        // `-uiTestResetNarrations` (phone smoke test) guarantees a fresh My
        // Narrations store so the record flow always starts at paragraph one,
        // regardless of what earlier test runs left behind.
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetNarrations") {
            repository.resetAll()
        }
        #endif
        Task { await self.reloadNarrations() }
    }

    /// All seven rungs, L0…L3.
    nonisolated public static func defaultSources() -> [any NeedsSource] {
        [
            SeededNeedsSource(),
            SnapshotNeedsSource(),
            PoetryDBNeedsSource(),
            GutendexNeedsSource(),
            InternetArchiveNeedsSource(),
            WikisourceNeedsSource(),
            LibriVoxForumNeedsSource()
        ]
    }

    nonisolated public static func defaultCache() -> any NeedsCaching {
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Voxglass/needs-cache.json")
        return FileNeedsCache(url: cacheURL, clock: SystemClock())
    }

    /// Drains the ladder stream (floor then enriched) into the surface.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        for await snapshot in aggregator.stream(for: .iOS) {
            apply(snapshot)
        }
    }

    /// One-shot ladder run used on surface appear / pull-to-refresh.
    public func refreshOnce() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await aggregator.refresh(platform: .iOS)
        apply(snapshot)
    }

    private func apply(_ snapshot: NeedsSnapshot) {
        lastSnapshot = snapshot
        needs = snapshot.needs
        featured = snapshot.featured
        freshness = snapshot.freshness
    }

    // MARK: - My Narrations

    public func reloadNarrations() async {
        myNarrations = await repository.allProjects()
        await repository.backfillProjectDetailsIfNeeded(knownNeeds: needs)
        myNarrations = await repository.allProjects()
    }

    /// Persists a narration project (the flow already wrote the bytes), projects
    /// it to `ProductionPreviewStore`, and relays it to the watch. Idempotent.
    public func save(_ project: AudiobookProject) async {
        try? await repository.save(project)
        await publish(project)
        await reloadNarrations()
    }

    public func delete(_ project: AudiobookProject) async {
        try? await repository.delete(project.id)
        await reloadNarrations()
    }

    // MARK: - Projection to preview store + watch

    private func publish(_ project: AudiobookProject) async {
        guard let phoneProduction else { return }
        await phoneProduction.localPublish(project)
    }
}
