import Foundation

/// One rung of the source ladder (NARRATION_NEEDS_SPEC §2, §4.2).
///
/// Contract: a source is *optional and independently failable*. Its `fetch`
/// may throw on any failure (network, parse, auth wall); the aggregator maps
/// every throw to an empty contribution and a diagnostics event — a child
/// never rethrows into the group (§2.1.2). Sources depend only on the
/// `HTTPFetching` seam and the `Clock`.
public protocol NeedsSource: Sendable {
    var id: NeedSourceID { get }
    var descriptor: NeedsSourceDescriptor { get }
    func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed]
}

public extension NeedsSource {
    var descriptor: NeedsSourceDescriptor {
        NeedsSourceDescriptors.descriptor(for: id)
    }
}
