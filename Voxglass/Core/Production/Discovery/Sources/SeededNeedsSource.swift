import Foundation

/// L0 — the floor (NARRATION_NEEDS_SPEC §2, §2.1). Reads the bundled
/// `needs-seed.json` and can never fail: if the seed is missing or malformed
/// the build is broken (G-18). The seed guarantees a non-empty, PD-safe pool
/// offline, forever.
public struct SeededNeedsSource: NeedsSource {
    public var id: NeedSourceID { .seed }

    public init() {}

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        let bundleURL = try bundleResourceURL()
        let data = try Data(contentsOf: bundleURL)
        return try decode(data, clock: clock)
    }

    public func decode(_ data: Data, clock: any Clock) throws -> [NarrationNeed] {
        let envelope = try NeedsJSONCoding.decoder.decode(SeedEnvelope.self, from: data)
        let now = clock.now
        return envelope.entries.map { entry in
            entry.toNeed(firstSeen: NeedsDiscoveryConstants.seedFirstSeen, lastConfirmed: now)
        }
    }

    private func bundleResourceURL() throws -> URL {
        if let url = Bundle.module.url(forResource: "needs-seed", withExtension: "json") {
            return url
        }
        // Fallback for older layouts where the copy kept its subdirectory.
        if let url = Bundle.module.url(forResource: "needs-seed", withExtension: "json", subdirectory: "Resources") {
            return url
        }
        throw DiscoveryError.resourceMissing("needs-seed.json")
    }
}

/// Compact seed format — kept small and readable; expanded to `NarrationNeed`
/// on load. `grade`/`signal`/dates are optional and default to the sensible
/// discovery defaults.
public struct SeedEnvelope: Sendable, Codable, Equatable {
    public var version: Int
    public var entries: [SeedEntry]

    public init(version: Int, entries: [SeedEntry]) {
        self.version = version
        self.entries = entries
    }
}

public struct SeedEntry: Sendable, Codable, Equatable {
    public var title: String
    public var author: String
    public var subject: String?
    public var kind: String?
    public var estSeconds: Int
    public var sourcePageURL: String?
    public var sourceEPUBURL: String?
    public var text: String?
    public var grade: String?
    public var signal: String?
    public var pinnedWeekOf: String?
    public var pinnedMonthOf: String?

    public init(
        title: String,
        author: String,
        subject: String? = nil,
        kind: String? = nil,
        estSeconds: Int,
        sourcePageURL: String? = nil,
        sourceEPUBURL: String? = nil,
        text: String? = nil,
        grade: String? = nil,
        signal: String? = nil,
        pinnedWeekOf: String? = nil,
        pinnedMonthOf: String? = nil
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.kind = kind
        self.estSeconds = estSeconds
        self.sourcePageURL = sourcePageURL
        self.sourceEPUBURL = sourceEPUBURL
        self.text = text
        self.grade = grade
        self.signal = signal
        self.pinnedWeekOf = pinnedWeekOf
        self.pinnedMonthOf = pinnedMonthOf
    }

    func toNeed(firstSeen: Date, lastConfirmed: Date) -> NarrationNeed {
        let grade: WorkGrade = self.grade == "practice" ? .practice : .submittable
        let signal: NeedSignal = NeedSignal(rawValue: self.signal ?? "") ?? .evergreen
        let pinnedWeek = pinnedWeekOf.flatMap { NeedsJSONCoding.isoDate($0) }
        let pinnedMonth = pinnedMonthOf.flatMap { NeedsJSONCoding.isoDate($0) }
        let work = NarratableWork(
            title: title,
            author: author,
            subject: subject ?? kind,
            grade: grade,
            estSeconds: estSeconds,
            sourcePageURL: sourcePageURL.flatMap(URL.init(string:)),
            sourceEPUBURL: sourceEPUBURL.flatMap(URL.init(string:)),
            text: text,
            pinnedWeekOf: pinnedWeek,
            pinnedMonthOf: pinnedMonth
        )
        return NarrationNeed(
            work: work,
            signal: signal,
            strength: seedStrength(for: signal),
            provenance: NeedProvenance(
                sources: [.seed],
                firstSeen: firstSeen,
                lastConfirmed: lastConfirmed,
                pdBasis: .curatorVerified
            )
        )
    }

    private func seedStrength(for signal: NeedSignal) -> Int {
        // Seed works are evergreen; strength is informational and ranked by signal anyway.
        50
    }
}
