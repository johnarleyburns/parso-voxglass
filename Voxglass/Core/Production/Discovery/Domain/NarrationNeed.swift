import Foundation

// MARK: - Need signals

/// Why a work is a "need" (NARRATION_NEEDS_SPEC §0.4, §5). Ordered from
/// highest liveness to lowest; the ranker treats this order as its primary key.
public enum NeedSignal: String, Sendable, Codable, CaseIterable, Comparable {
    case openProjectNeedsReader
    case proofListenerNeeded
    case weeklyFeatured
    case catalogGap
    case evergreen

    /// Deterministic priority for ranking (lower = earlier).
    public var priority: Int {
        switch self {
        case .openProjectNeedsReader: return 0
        case .proofListenerNeeded: return 1
        case .weeklyFeatured: return 2
        case .catalogGap: return 3
        case .evergreen: return 4
        }
    }

    public static func < (lhs: NeedSignal, rhs: NeedSignal) -> Bool {
        lhs.priority < rhs.priority
    }
}

// MARK: - Platforms, length, grade, PD basis

public enum Platform: String, Sendable, Codable {
    case iOS
    case mac
}

/// `.short` iff `estSeconds <= shortWorkCeilingSeconds` — exactly LibriVox's
/// own definition of short works ("less than 1 hour read by individuals").
public enum LengthClass: String, Sendable, Codable {
    case short
    case long
}

public enum WorkGrade: String, Sendable, Codable {
    /// Records to personal/Internet Archive only; never surfaced as LibriVox-ready.
    case practice
    /// LibriVox-eligible: PD-verified and citable.
    case submittable
}

public enum PDBasis: String, Sendable, Codable {
    case gutenbergSourced
    case iaVerifiedEdition
    case curatorVerified
    case usOnly
    case unverified
}

/// The work offered by a narration need (NARRATION_NEEDS_SPEC §5 — the base
/// plan's "NarratableWork" extended for discovery).
public struct NarratableWork: Sendable, Codable, Equatable {
    public var title: String
    public var author: String
    public var subject: String?
    public var lengthClass: LengthClass
    public var grade: WorkGrade
    public var estSeconds: Int
    public var sourcePageURL: URL?
    public var sourceEPUBURL: URL?
    public var text: String?
    public var pinnedWeekOf: Date?
    public var pinnedMonthOf: Date?

    public init(
        title: String,
        author: String,
        subject: String? = nil,
        lengthClass: LengthClass? = nil,
        grade: WorkGrade = .submittable,
        estSeconds: Int = 0,
        sourcePageURL: URL? = nil,
        sourceEPUBURL: URL? = nil,
        text: String? = nil,
        pinnedWeekOf: Date? = nil,
        pinnedMonthOf: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.lengthClass = lengthClass ?? LengthClass.classification(forEstSeconds: estSeconds)
        self.grade = grade
        self.estSeconds = estSeconds
        self.sourcePageURL = sourcePageURL
        self.sourceEPUBURL = sourceEPUBURL
        self.text = text
        self.pinnedWeekOf = pinnedWeekOf
        self.pinnedMonthOf = pinnedMonthOf
    }
}

extension LengthClass {
    /// Centralized derivation (NARRATION_NEEDS_SPEC §5, G-10). A 59-minute work
    /// is `.short`; a 61-minute work is `.long`; the boundary itself is `.short`.
    public static func classification(forEstSeconds seconds: Int, ceiling: Int = NeedsDiscoveryConstants.shortWorkCeilingSeconds) -> LengthClass {
        seconds <= ceiling ? .short : .long
    }
}

// MARK: - Need provenance

/// Provenance of a narration need: which sources contributed, the PD basis,
/// and the LibriVox thread to submit to (if any).
public struct NeedProvenance: Sendable, Codable, Equatable {
    public var sources: [NeedSourceID]
    public var firstSeen: Date
    public var lastConfirmed: Date
    public var pdBasis: PDBasis
    public var libriVoxThreadURL: URL?
    /// Edition year for the rolling IA PD line (§6) when the source attaches one.
    public var editionYear: Int?

    public init(
        sources: [NeedSourceID],
        firstSeen: Date,
        lastConfirmed: Date,
        pdBasis: PDBasis,
        libriVoxThreadURL: URL? = nil,
        editionYear: Int? = nil
    ) {
        self.sources = sources
        self.firstSeen = firstSeen
        self.lastConfirmed = lastConfirmed
        self.pdBasis = pdBasis
        self.libriVoxThreadURL = libriVoxThreadURL
        self.editionYear = editionYear
    }
}

// MARK: - Narration need

/// A discovered opportunity to narrate a public-domain work (NARRATION_NEEDS_SPEC §5).
public struct NarrationNeed: Sendable, Codable, Identifiable, Equatable {
    /// `NeedID` — SHA256Hex(normalize(author) | normalize(title) | normalizedSourceHost).
    public let id: String
    public let work: NarratableWork
    public let signal: NeedSignal
    /// 0…100 rank input assigned by the contributing source (§7).
    public let strength: Int
    public let provenance: NeedProvenance
    /// Open-project needs expire; evergreen needs are nil.
    public let expiresAt: Date?

    /// DERIVED, never stored (§10): the record action is offered for every need
    /// regardless of length (N-1). The short-work ceiling survives only as a
    /// *discovery* signal ("finishable in one sitting"), never as a gate on the
    /// record action (§0.6 N-1, §8.3).
    public var narratableOn: Set<Platform> {
        [.iOS, .mac]
    }

    public var isSubmittable: Bool { work.grade == .submittable }

    public init(
        id: String? = nil,
        work: NarratableWork,
        signal: NeedSignal,
        strength: Int,
        provenance: NeedProvenance,
        expiresAt: Date? = nil
    ) {
        self.id = id ?? NeedID.compute(work: work)
        self.work = work
        self.signal = signal
        self.strength = strength
        self.provenance = provenance
        self.expiresAt = expiresAt
    }
}

// MARK: - Snapshot

/// Freshness of the surface (NARRATION_NEEDS_SPEC §5) — drives at most a
/// subtle caption; never an error.
public enum Freshness: String, Sendable, Codable, Equatable {
    case liveEnriched
    case cached
    case seedOnly
}

/// What the aggregator streams: ranked, deduped, PD-safe, non-empty needs
/// plus the featured slot for this platform.
public struct NeedsSnapshot: Sendable, Codable, Equatable {
    public var needs: [NarrationNeed]
    public var featured: NarrationNeed?
    public var freshness: Freshness

    public init(needs: [NarrationNeed], featured: NarrationNeed? = nil, freshness: Freshness = .seedOnly) {
        self.needs = needs
        self.featured = featured
        self.freshness = freshness
    }

    public var shortNeeds: [NarrationNeed] { needs.filter { $0.work.lengthClass == .short } }
    public var longNeeds: [NarrationNeed] { needs.filter { $0.work.lengthClass == .long } }
}

// MARK: - Need ID

/// Deterministic identity for dedupe across sources (§2.2). Uses the bundled
/// `SHA256Hex` (never `Hasher`, whose seed changes per launch — G-4).
public enum NeedID {
    public static func compute(author: String, title: String, sourceHost: String?) -> String {
        SHA256Hex.hex(joining: [normalize(author), normalize(title), normalize(sourceHost ?? "")])
    }

    public static func compute(work: NarratableWork) -> String {
        compute(author: work.author, title: work.title, sourceHost: work.sourcePageURL?.host)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
