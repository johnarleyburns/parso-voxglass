import Foundation

/// Storage policy for production audio on the watch. Spec §13.6 rule 4: the watch
/// keeps at most 200 MB of production audio and evicts least-recently-reviewed
/// audio first.
public struct WatchProductionStoragePolicy: Sendable {

    public static let maxProductionBytes = 200 * 1024 * 1024

    public struct Item: Sendable, Equatable {
        public var paragraphID: UUID
        public var byteCount: Int
        public var lastQueuedAt: Date
        public var lastReviewedAt: Date?
        public init(paragraphID: UUID, byteCount: Int, lastQueuedAt: Date, lastReviewedAt: Date? = nil) {
            self.paragraphID = paragraphID
            self.byteCount = byteCount
            self.lastQueuedAt = lastQueuedAt
            self.lastReviewedAt = lastReviewedAt
        }
    }

    public init() {}

    /// Total bytes of the given items.
    public func totalBytes(of items: [Item]) -> Int {
        items.reduce(0) { $0 + $1.byteCount }
    }

    /// The ordered set of paragraph IDs to evict so the remaining total fits under the
    /// cap, evicting least-recently-queued first. Never evicts `keep` paragraph IDs.
    public func evictionCandidates(
        items: [Item],
        cap: Int = WatchProductionStoragePolicy.maxProductionBytes,
        keep: Set<UUID> = []
    ) -> [UUID] {
        let sorted = items
            .filter { !keep.contains($0.paragraphID) }
            .sorted {
                ($0.lastReviewedAt ?? $0.lastQueuedAt) < ($1.lastReviewedAt ?? $1.lastQueuedAt)
            }

        var total = totalBytes(of: items)
        var candidates: [UUID] = []
        for item in sorted {
            guard total > cap else { break }
            total -= item.byteCount
            candidates.append(item.paragraphID)
        }
        return candidates
    }
}
