import Foundation

/// Where a candidate position sits relative to a baseline, in book order.
public enum BookProgressOrder: Equatable, Sendable {
    case behind
    case equalOrWithinTolerance
    case ahead
    case indeterminate
}

/// Pure "furthest progress wins" comparison for positions in one book.
/// Chapter order first, offset within the chapter second; timestamps never
/// override known book-order progress (they only break exact ties in `furthest`).
public enum BookProgressResolver {
    public static func compare(
        _ candidate: PlaybackPosition,
        to baseline: PlaybackPosition,
        in chapters: [Chapter],
        tolerance: TimeInterval = 2
    ) -> BookProgressOrder {
        guard candidate.bookID == baseline.bookID else { return .indeterminate }
        let sorted = chapters.naturallySorted()
        guard let c = rank(candidate, in: sorted), let b = rank(baseline, in: sorted) else {
            return .indeterminate
        }
        if c.index != b.index { return c.index > b.index ? .ahead : .behind }
        let delta = candidate.position - baseline.position
        if abs(delta) <= tolerance { return .equalOrWithinTolerance }
        return delta > 0 ? .ahead : .behind
    }

    /// The known-furthest valid candidate. Invalid or unmappable positions are
    /// ignored; ties (same chapter, within 0.001 s) go to the newer timestamp.
    public static func furthest(
        _ positions: [PlaybackPosition],
        in chapters: [Chapter]
    ) -> PlaybackPosition? {
        let sorted = chapters.naturallySorted()
        var best: (position: PlaybackPosition, index: Int)?
        for position in positions {
            guard let r = rank(position, in: sorted) else { continue }
            guard let current = best else { best = (position, r.index); continue }
            let ahead: Bool
            if r.index != current.index {
                ahead = r.index > current.index
            } else if abs(position.position - current.position.position) > 0.001 {
                ahead = position.position > current.position.position
            } else {
                ahead = position.updatedAt > current.position.updatedAt
            }
            if ahead { best = (position, r.index) }
        }
        return best?.position
    }

    private static func rank(_ position: PlaybackPosition, in sorted: [Chapter]) -> (index: Int, Void)? {
        guard position.position.isFinite, position.position >= 0,
              let index = sorted.firstIndex(where: { $0.id == position.chapterID }),
              sorted[index].bookID == position.bookID else { return nil }
        return (index, ())
    }
}
