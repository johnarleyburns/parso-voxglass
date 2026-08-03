import Foundation

public enum FeaturedCadence: Sendable {
    case weekly
    case monthly
}

/// The featured slot is always present and correct on-device, independent of
/// the network (NARRATION_NEEDS_SPEC §8):
/// 1. A pin for this period (set by a fresher rung) wins.
/// 2. Otherwise a deterministic SplitMix64 rotation seeded by (sorted ids,
///    year): same pool + same period → same pick on every device. NOT
///    Swift.Hasher (reseeds per launch) and NOT a fetched value.
/// 3. Stale pins (older than one period) are ignored, falling back to rotation.
/// An empty pool returns nil (cannot happen with the seed — G-18).
public struct FeaturedSelector: Sendable {
    public init() {}

    public func featured(from pool: [NarrationNeed], cadence: FeaturedCadence, on date: Date) -> NarrationNeed? {
        guard !pool.isEmpty else { return nil }

        let currentPeriod = period(for: cadence, on: date)
        if let pinned = pinned(in: pool, cadence: cadence, matching: currentPeriod) {
            return pinned
        }

        let sortedIDs = pool.map(\.id).sorted()
        let joined = sortedIDs.joined(separator: "\n") + "\u{1F}" + String(currentPeriod)
        let seed = FNV1a(joined)
        var prng = SplitMix64(seed: seed)
        let index = Int(prng.next() % UInt64(pool.count))
        return pool[index]
    }

    // MARK: - Pins

    private func pinned(in pool: [NarrationNeed], cadence: FeaturedCadence, matching expectedPeriod: Int) -> NarrationNeed? {
        for need in pool {
            let pin: Date?
            switch cadence {
            case .weekly: pin = need.work.pinnedWeekOf
            case .monthly: pin = need.work.pinnedMonthOf
            }
            guard let pin else { continue }
            if period(for: cadence, on: pin) == expectedPeriod {
                return need
            }
        }
        return nil
    }

    /// Canonical period index: weekly → ISO year-week (UTC); monthly → year*12+month (UTC).
    func period(for cadence: FeaturedCadence, on date: Date) -> Int {
        switch cadence {
        case .weekly:
            let c = Calendar(identifier: .iso8601)
            var utc = c
            utc.timeZone = TimeZone(identifier: "UTC")!
            let comps = utc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return (comps.yearForWeekOfYear ?? 0) * 100 + (comps.weekOfYear ?? 0)
        case .monthly:
            let c = Calendar(identifier: .gregorian)
            var utc = c
            utc.timeZone = TimeZone(identifier: "UTC")!
            let comps = utc.dateComponents([.year, .month], from: date)
            return (comps.year ?? 0) * 12 + (comps.month ?? 0)
        }
    }
}

/// FNV-1a 64-bit — a stable, deterministic string hash (unlike `Hasher`).
func FNV1a(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return hash
}

/// SplitMix64 PRNG — deterministic across launches and devices.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
