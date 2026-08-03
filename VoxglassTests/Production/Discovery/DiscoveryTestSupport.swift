import Foundation
import VoxglassCore
import VoxglassCoreTestSupport

/// Shared builders for discovery tests.
func makeNeed(
    title: String,
    author: String = "A Poet",
    estSeconds: Int = 60,
    signal: NeedSignal = .evergreen,
    grade: WorkGrade = .submittable,
    host: String? = "gutenberg.org",
    subject: String? = "poem",
    sourceURL: String? = nil,
    pdBasis: PDBasis = .gutenbergSourced,
    text: String? = nil,
    pinnedWeekOf: Date? = nil,
    pinnedMonthOf: Date? = nil,
    sources: [NeedSourceID] = [.gutendex],
    expiresAt: Date? = nil
) -> NarrationNeed {
    let pageURL: URL?
    if let sourceURL {
        pageURL = URL(string: sourceURL)
    } else if let host {
        pageURL = URL(string: "https://\(host)/ebooks/1")
    } else {
        pageURL = nil
    }
    let work = NarratableWork(
        title: title,
        author: author,
        subject: subject,
        grade: grade,
        estSeconds: estSeconds,
        sourcePageURL: pageURL,
        text: text,
        pinnedWeekOf: pinnedWeekOf,
        pinnedMonthOf: pinnedMonthOf
    )
    return NarrationNeed(
        work: work,
        signal: signal,
        strength: 50,
        provenance: NeedProvenance(
            sources: sources,
            firstSeen: NeedsDiscoveryConstants.seedFirstSeen,
            lastConfirmed: NeedsDiscoveryConstants.seedFirstSeen,
            pdBasis: pdBasis
        ),
        expiresAt: expiresAt
    )
}

/// A fully-wired aggregator: the real seed + a set of controllable fake rungs.
func makeAggregator(
    fetcher: any HTTPFetching,
    extraSources: [any NeedsSource] = [],
    cache: any NeedsCaching = InMemoryNeedsCache(),
    clock: any Clock = FixedClock()
) -> LadderNeedsAggregator {
    var sources: [any NeedsSource] = [SeededNeedsSource()]
    sources.append(contentsOf: extraSources)
    return LadderNeedsAggregator(sources: sources, cache: cache, fetcher: fetcher, clock: clock)
}

func drain(_ stream: AsyncStream<NeedsSnapshot>) async -> [NeedsSnapshot] {
    var snapshots: [NeedsSnapshot] = []
    for await snapshot in stream {
        snapshots.append(snapshot)
    }
    return snapshots
}
