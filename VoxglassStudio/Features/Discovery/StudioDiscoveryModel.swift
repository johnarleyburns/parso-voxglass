import Foundation
import Observation
import VoxglassCore

/// The Studio's discovery composition root (NARRATION_NEEDS_SPEC §11.2): same
/// ladder as the phone, surfaced for the Mac. Short and long works are both
/// narratable here.
@MainActor
@Observable
public final class StudioDiscoveryModel {
    public let aggregator: LadderNeedsAggregator

    public private(set) var needs: [NarrationNeed] = []
    public private(set) var featured: NarrationNeed?
    public private(set) var freshness: Freshness = .seedOnly
    public private(set) var isRefreshing = false

    public init(
        sources: [any NeedsSource] = StudioDiscoveryModel.defaultSources(),
        cache: any NeedsCaching = StudioDiscoveryModel.defaultCache(),
        fetcher: any HTTPFetching = StudioURLSessionFetcher(),
        clock: any Clock = SystemClock()
    ) {
        self.aggregator = LadderNeedsAggregator(sources: sources, cache: cache, fetcher: fetcher, clock: clock)
    }

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
            .appendingPathComponent("Voxglass Studio/needs-cache.json")
        return FileNeedsCache(url: cacheURL, clock: SystemClock())
    }

    public func refreshOnce() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await aggregator.refresh(platform: .mac)
        needs = snapshot.needs
        featured = snapshot.featured
        freshness = snapshot.freshness
    }
}
