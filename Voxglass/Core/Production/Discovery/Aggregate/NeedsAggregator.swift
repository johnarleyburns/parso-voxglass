import Foundation

/// Composes the source ladder (NARRATION_NEEDS_SPEC §2, §4.3). The core
/// contract (G-13):
/// 1. `stream(for:)` emits its first element **synchronously-fast** from
///    L0 ∪ last-good cache — no network awaited before the first emission.
/// 2. Every rung call is isolated: `try?`-wrapped, per-rung timeout, guarded by
///    a per-rung circuit breaker. A child **never rethrows** into the group;
///    a throw/timeout/redirect/parse-failure maps to an empty contribution.
/// 3. The aggregator never returns empty while the seed loads (G-18).
public struct LadderNeedsAggregator: Sendable {
    public let sources: [any NeedsSource]
    public let cache: any NeedsCaching
    public let fetcher: any HTTPFetching
    public let clock: any Clock
    public let verifier: PDVerifier
    public let ranker: NeedsRanker
    public let deduplicator: NeedDeduplicator
    public let featured: FeaturedSelector

    public init(
        sources: [any NeedsSource],
        cache: any NeedsCaching,
        fetcher: any HTTPFetching,
        clock: any Clock,
        verifier: PDVerifier = PDVerifier(),
        ranker: NeedsRanker = NeedsRanker(),
        deduplicator: NeedDeduplicator = NeedDeduplicator(),
        featured: FeaturedSelector = FeaturedSelector()
    ) {
        self.sources = sources
        self.cache = cache
        self.fetcher = fetcher
        self.clock = clock
        self.verifier = verifier
        self.ranker = ranker
        self.deduplicator = deduplicator
        self.featured = featured
    }

    // MARK: - Streaming

    /// Two-phase stream: floor first (instant), then the enriched ladder result.
    public func stream(for platform: Platform) -> AsyncStream<NeedsSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                let cached = await cache.load()
                let floor = await buildSnapshot(platform: platform, contributions: await seedContributions(), cached: cached)
                continuation.yield(floor)

                let enriched = await runLadder(platform: platform)
                continuation.yield(enriched)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs the ladder once and returns the enriched snapshot (also used by the
    /// runtime refresher and the UI's on-appear refresh).
    public func refresh(platform: Platform) async -> NeedsSnapshot {
        let cached = await cache.load()
        let floor = await buildSnapshot(platform: platform, contributions: await seedContributions(), cached: cached)
        return await runLadder(platform: platform, floor: floor)
    }

    // MARK: - Ladder

    private func runLadder(platform: Platform, floor: NeedsSnapshot? = nil) async -> NeedsSnapshot {
        let cached = await cache.load()
        var contributions = await seedContributions()
        if let floor {
            contributions += floor.needs
        } else if let cached {
            contributions += cached.needs
        }

        var liveRungs = 0
        await withTaskGroup(of: [NarrationNeed].self) { group in
            for source in sources where source.id != .seed {
                group.addTask {
                    await self.runRung(source)
                }
            }
            for await needs in group {
                if !needs.isEmpty { liveRungs += 1 }
                contributions.append(contentsOf: needs)
            }
        }

        let snapshot = await buildSnapshot(platform: platform, contributions: contributions, cached: cached, liveRungs: liveRungs)
        await cache.save(snapshot)
        return snapshot
    }

    /// A single isolated rung: circuit-breaker check, timeout, error → empty.
    private func runRung(_ source: NeedsSource) async -> [NarrationNeed] {
        let now = clock.now
        let state = await cache.state(for: source.id)
        var breaker = CircuitBreaker(consecutiveFailures: state.consecutiveFailures, openUntil: state.openUntil)
        guard !breaker.shouldSkip(now: now) else { return [] }

        do {
            let needs = try await withRungTimeout(source)
            breaker.recordSuccess()
            await cache.setState(.init(breaker: breaker, lastFetch: now, lastSuccess: now), for: source.id)
            return needs
        } catch {
            breaker.recordFailure(now: now)
            await cache.setState(.init(breaker: breaker, lastFetch: now, lastSuccess: nil), for: source.id)
            return []
        }
    }

    private func withRungTimeout(_ source: NeedsSource) async throws -> [NarrationNeed] {
        let timeout = source.descriptor.defaultTimeout
        guard timeout > 0 else {
            return try await source.fetch(using: fetcher, clock: clock)
        }
        return try await withThrowingTaskGroup(of: [NarrationNeed].self) { group in
            group.addTask { try await source.fetch(using: self.fetcher, clock: self.clock) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw HTTPFetchError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return [] }
            return first
        }
    }

    // MARK: - Snapshot assembly

    private func seedContributions() async -> [NarrationNeed] {
        guard let seed = sources.first(where: { $0.id == .seed }) else { return [] }
        return (try? await seed.fetch(using: fetcher, clock: clock)) ?? []
    }

    private func buildSnapshot(
        platform: Platform,
        contributions: [NarrationNeed],
        cached: NeedsSnapshot?,
        liveRungs: Int = 0
    ) async -> NeedsSnapshot {
        var all = contributions
        if let cached {
            all += cached.needs
        }

        let deduped = deduplicator.dedupe(all).map(normalizePD)
        let ranked = ranker.rank(deduped, for: platform, taste: [])

        let cadence: FeaturedCadence
        let featuredPool: [NarrationNeed]
        switch platform {
        case .iOS:
            cadence = .weekly
            featuredPool = ranked.filter { $0.work.lengthClass == .short }
        case .mac:
            cadence = .monthly
            featuredPool = ranked.filter { $0.work.lengthClass == .long }
        }
        let featuredNeed = featured.featured(from: featuredPool, cadence: cadence, on: clock.now)

        let freshness: Freshness = {
            if liveRungs > 0 { return .liveEnriched }
            return cached != nil ? .cached : .seedOnly
        }()

        return NeedsSnapshot(needs: ranked, featured: featuredNeed, freshness: freshness)
    }

    /// PD gate (G-16): no work may be `.submittable` with an unverified basis.
    private func normalizePD(_ need: NarrationNeed) -> NarrationNeed {
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let currentYear = utc.component(.year, from: clock.now)
        let basis = verifier.verify(need, currentYear: currentYear)

        var work = need.work
        if basis == .unverified, work.grade == .submittable {
            work.grade = .practice
        }
        var provenance = need.provenance
        provenance.pdBasis = basis
        return NarrationNeed(
            id: need.id,
            work: work,
            signal: need.signal,
            strength: need.strength,
            provenance: provenance,
            expiresAt: need.expiresAt
        )
    }
}
