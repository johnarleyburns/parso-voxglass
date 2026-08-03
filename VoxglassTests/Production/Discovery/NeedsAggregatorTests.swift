import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct NeedsAggregatorTests {

    @Test func allSourcesFail_seedFloorReturnedNonEmpty() async {
        // Every live rung throws/times-out → the result is the seed: non-empty,
        // ranked, PD-safe (§12.1, G-13).
        let fetcher = StubFetcher().failAll()
        let fakes: [any NeedsSource] = [
            FakeNeedsSource(id: .snapshot, fetchError: .transport),
            FakeNeedsSource(id: .gutendex, fetchError: .timeout),
            FakeNeedsSource(id: .poetryDB, fetchError: .transport),
            FakeNeedsSource(id: .internetArchive, fetchError: .transport),
            FakeNeedsSource(id: .wikisource, fetchError: .transport),
            FakeNeedsSource(id: .libriVoxForum, fetchError: .authWall)
        ]
        let aggregator = makeAggregator(fetcher: fetcher, extraSources: fakes)
        let snapshots = await drain(aggregator.stream(for: .iOS))

        let enriched = snapshots.last!
        #expect(!enriched.needs.isEmpty)
        #expect(enriched.shortNeeds.count >= 100)
        #expect(enriched.longNeeds.count >= 20)

        // Every need is PD-safe: nothing is `.submittable` with an unverified basis.
        for need in enriched.needs {
            if need.work.grade == .submittable {
                #expect(need.provenance.pdBasis != .unverified)
            }
        }
        // Ranked by signal priority.
        let ranked = enriched.needs.map(\.signal.priority)
        #expect(ranked == ranked.sorted())
        #expect(enriched.freshness == .cached || enriched.freshness == .seedOnly)
    }

    @Test func firstStreamElementIsInstantFloor() async {
        // A rung that never resolves must not delay the first emission.
        let hanging = StubFetcher().setDefault(.init(delay: 60))
        let aggregator = makeAggregator(fetcher: hanging)
        let first = await aggregator.stream(for: .iOS).first { _ in true }
        #expect(first != nil)
        #expect(first!.needs.count >= 100)
        #expect(first!.freshness == .seedOnly)
    }

    @Test func mergeAndDedupe_byNeedID() async {
        // The bundled seed's "Hope" carries a www.gutenberg.org source page;
        // matching needs must use the same host to land on the same NeedID.
        let live = makeNeed(
            title: "Hope is the thing with feathers", author: "Emily Dickinson",
            signal: .weeklyFeatured, host: "www.gutenberg.org", sources: [.snapshot]
        )
        let fake = FakeNeedsSource(id: .snapshot, needs: [live])
        let aggregator = makeAggregator(fetcher: StubFetcher().failAll(), extraSources: [fake])
        let snapshots = await drain(aggregator.stream(for: .iOS))
        let merged = snapshots.last!.needs.filter { $0.work.title == "Hope is the thing with feathers" }
        #expect(merged.count == 1)
        #expect(merged.first!.signal == .weeklyFeatured) // strongest signal wins
        #expect(merged.first!.provenance.sources.contains(.seed))
        #expect(merged.first!.provenance.sources.contains(.snapshot))
    }

    @Test func provenanceUnionsAndKeepsThreadURL() async {
        // Matches the bundled seed's "Annabel Lee" (www.gutenberg.org host).
        let forumMatching = NarrationNeed(
            work: NarratableWork(
                title: "Annabel Lee", author: "Edgar Allan Poe", subject: "poem",
                grade: .practice, estSeconds: 90,
                sourcePageURL: URL(string: "https://www.gutenberg.org/ebooks/842")
            ),
            signal: .openProjectNeedsReader,
            strength: 95,
            provenance: NeedProvenance(
                sources: [.libriVoxForum],
                firstSeen: NeedsDiscoveryConstants.seedFirstSeen,
                lastConfirmed: NeedsDiscoveryConstants.seedFirstSeen,
                pdBasis: .unverified,
                libriVoxThreadURL: URL(string: "https://forum.librivox.org/viewtopic.php?t=1")
            )
        )
        let aggregator = makeAggregator(fetcher: StubFetcher().failAll(), extraSources: [FakeNeedsSource(id: .libriVoxForum, needs: [forumMatching])])
        let snapshots = await drain(aggregator.stream(for: .iOS))
        let merged = snapshots.last!.needs.filter { $0.work.title == "Annabel Lee" }
        #expect(merged.count == 1)
        #expect(merged.first!.provenance.libriVoxThreadURL != nil)
        #expect(merged.first!.signal == .openProjectNeedsReader)
        #expect(merged.first!.isSubmittable) // kept the stronger (seed) PD basis
    }

    @Test func pdGate_neverSubmittableWhenUnverified() async {
        let dubious = makeNeed(
            title: "Recent Mystery", author: "A Modern Writer",
            grade: .submittable, host: nil, sourceURL: "https://example.com/work",
            pdBasis: .unverified
        )
        let fake = FakeNeedsSource(id: .snapshot, needs: [dubious])
        let aggregator = makeAggregator(fetcher: StubFetcher().failAll(), extraSources: [fake])
        let snapshots = await drain(aggregator.stream(for: .iOS))
        let normalized = snapshots.last!.needs.first { $0.work.title == "Recent Mystery" }
        #expect(normalized != nil)
        #expect(normalized!.work.grade == .practice)
        #expect(!normalized!.isSubmittable)
    }

    @Test func circuitBreakerSkipsFlappingRung() async {
        let flapping = FakeNeedsSource(id: .snapshot, fetchError: .transport)
        let cache = InMemoryNeedsCache()
        let aggregator = makeAggregator(fetcher: StubFetcher().failAll(), extraSources: [flapping], cache: cache)

        // Threshold is 3 consecutive failures → breaker trips on the third run.
        _ = await aggregator.refresh(platform: .iOS)
        _ = await aggregator.refresh(platform: .iOS)
        #expect(flapping.callCount == 2)

        _ = await aggregator.refresh(platform: .iOS)
        #expect(flapping.callCount == 3)

        // Now open: the 4th run skips the rung entirely (no new fetch).
        _ = await aggregator.refresh(platform: .iOS)
        #expect(flapping.callCount == 3)
    }

    @Test func liveRungEnrichesFreshnessAndCache() async {
        let cache = InMemoryNeedsCache()
        let live = makeNeed(title: "Live Only Poem", author: "Live Poet", sources: [.snapshot])
        let fake = FakeNeedsSource(id: .snapshot, needs: [live])
        let aggregator = makeAggregator(fetcher: StubFetcher().failAll(), extraSources: [fake], cache: cache)

        let snapshots = await drain(aggregator.stream(for: .iOS))
        let first = snapshots.first!
        let enriched = snapshots.last!

        #expect(first.freshness == .seedOnly)
        #expect(enriched.freshness == .liveEnriched)
        #expect(enriched.needs.contains { $0.work.title == "Live Only Poem" })

        // The enriched snapshot is persisted as last-good.
        let loaded = await cache.load()
        #expect(loaded != nil)
        #expect(loaded!.needs.contains { $0.work.title == "Live Only Poem" })
    }
}
