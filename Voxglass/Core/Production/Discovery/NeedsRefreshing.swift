import Foundation

/// Runtime refresh for the discovery surface (NARRATION_NEEDS_SPEC §4.2, §9):
/// foreground on surface appear on both platforms, plus a discretionary
/// `BGAppRefreshTask` pre-warm on iOS. Never relied upon — the seed and the
/// deterministic featured pick make correctness independent of refresh.
public protocol NeedsRefreshing: Sendable {
    func refresh() async
}

public struct RuntimeNeedsRefresher: NeedsRefreshing {
    public let aggregator: LadderNeedsAggregator
    public let platform: Platform

    public init(aggregator: LadderNeedsAggregator, platform: Platform) {
        self.aggregator = aggregator
        self.platform = platform
    }

    /// Runs the ladder once and persists the enriched snapshot to the cache.
    public func refresh() async {
        _ = await aggregator.refresh(platform: platform)
    }
}
