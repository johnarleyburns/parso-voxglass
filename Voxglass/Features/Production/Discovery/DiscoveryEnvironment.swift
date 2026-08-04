import Foundation
import Observation
import VoxglassCore

/// The phone's discovery composition root (NARRATION_NEEDS_SPEC §11.1): owns
/// the ladder aggregator (all seven rungs), the last-good cache, the fetcher,
/// the deterministic clock, and the My Narrations store. The surface is always
/// full: the bundled seed floors it, live rungs enrich it, failures vanish.
@MainActor
@Observable
public final class DiscoveryEnvironment {
    public let aggregator: LadderNeedsAggregator
    public let store: NarrationProjectStore
    public let clock: any Clock

    public private(set) var needs: [NarrationNeed] = []
    public private(set) var featured: NarrationNeed?
    public private(set) var freshness: Freshness = .seedOnly
    public private(set) var myNarrations: [NarrationProject] = []
    public private(set) var isRefreshing = false

    public var lastSnapshot: NeedsSnapshot?

    public init(
        sources: [any NeedsSource] = DiscoveryEnvironment.defaultSources(),
        cache: any NeedsCaching = DiscoveryEnvironment.defaultCache(),
        fetcher: any HTTPFetching = URLSessionFetcher(),
        clock: any Clock = SystemClock(),
        store: NarrationProjectStore = NarrationProjectStore()
    ) {
        self.aggregator = LadderNeedsAggregator(sources: sources, cache: cache, fetcher: fetcher, clock: clock)
        self.store = store
        self.clock = clock
        #if DEBUG
        // `-uiTestResetNarrations` (phone smoke test) guarantees a fresh My
        // Narrations store so the record flow always starts at paragraph one,
        // regardless of what earlier test runs left behind.
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetNarrations") {
            store.deleteAll()
        }
        #endif
        self.myNarrations = store.loadAll()
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

    public func reloadNarrations() {
        myNarrations = store.loadAll()
    }

    public func save(_ project: NarrationProject) {
        store.save(project)
        reloadNarrations()
    }

    public func delete(_ project: NarrationProject) {
        store.delete(project.id)
        reloadNarrations()
    }
}
