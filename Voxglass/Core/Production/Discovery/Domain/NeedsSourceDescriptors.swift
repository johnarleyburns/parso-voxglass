import Foundation

/// All magic values for the discovery feature, centralized here (G-10/G-18).
public enum NeedsDiscoveryConstants {
    /// LibriVox's own short-work ceiling: 1 hour (NARRATION_NEEDS_SPEC §5, D-5).
    public static let shortWorkCeilingSeconds: Int = 3600
    /// Default per-rung timeout before a rung contributes nothing (§2.1).
    public static let rungTimeout: TimeInterval = 4.0
    /// Consecutive failures after which a rung is skipped for a cooldown (§2.1).
    public static let breakerFailureThreshold: Int = 3
    /// How long a tripped rung stays open (§2.1).
    public static let breakerCooldown: TimeInterval = 300
    /// Rolling US-PD line offset: an IA edition is PD if `year <= currentYear - 96`.
    public static let rollingCopyrightLine: Int = 96
    /// PoetryDB line-count ceiling for a short poem (§3.2).
    public static let shortPoemLineCeiling: Int = 40
    /// Seed build date used as `firstSeen` for bundled entries (kept stable so
    /// the deterministic featured rotation and dedupe never drift).
    public static let seedFirstSeen: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 12))!
    }()
}

/// Trust levels for the source ladder (§3.0).
public enum SourceTrust: String, Sendable, Codable {
    case highest, high, medium, low
}

/// The fixed, ordered set of discovery sources (L0…L3, §2).
public enum NeedSourceID: String, Sendable, Codable, CaseIterable {
    case seed
    case snapshot
    case poetryDB
    case gutendex
    case internetArchive
    case wikisource
    case libriVoxForum
}

/// Data-table description of a source (§3) — all magic values centralized.
public struct NeedsSourceDescriptor: Sendable, Codable, Equatable {
    public let id: NeedSourceID
    public let displayName: String
    public let role: String
    /// The floor (L0) is the only guaranteed rung; every other rung is optional.
    public let guaranteed: Bool
    public let defaultTimeout: TimeInterval
    public let cacheTTL: TimeInterval
    public let trust: SourceTrust

    public init(
        id: NeedSourceID,
        displayName: String,
        role: String,
        guaranteed: Bool,
        defaultTimeout: TimeInterval,
        cacheTTL: TimeInterval,
        trust: SourceTrust
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.guaranteed = guaranteed
        self.defaultTimeout = defaultTimeout
        self.cacheTTL = cacheTTL
        self.trust = trust
    }
}

public enum NeedsSourceDescriptors {
    public static let all: [NeedsSourceDescriptor] = [
        NeedsSourceDescriptor(
            id: .seed,
            displayName: "Bundled Seed",
            role: "The floor: pre-verified short + long public-domain works",
            guaranteed: true,
            defaultTimeout: 0,
            cacheTTL: .infinity,
            trust: .highest
        ),
        NeedsSourceDescriptor(
            id: .snapshot,
            displayName: "parso.guru Snapshot",
            role: "Pipeline-verified current LibriVox projects, pins, and great-books gaps",
            guaranteed: false,
            defaultTimeout: NeedsDiscoveryConstants.rungTimeout,
            cacheTTL: 24 * 3600,
            trust: .high
        ),
        NeedsSourceDescriptor(
            id: .poetryDB,
            displayName: "PoetryDB",
            role: "Fresh short poems (classic corpus; practice unless a Gutenberg source is attached)",
            guaranteed: false,
            defaultTimeout: NeedsDiscoveryConstants.rungTimeout,
            cacheTTL: 7 * 24 * 3600,
            trust: .medium
        ),
        NeedsSourceDescriptor(
            id: .gutendex,
            displayName: "Gutenberg (Gutendex)",
            role: "Short + long texts, US-PD by query",
            guaranteed: false,
            defaultTimeout: NeedsDiscoveryConstants.rungTimeout,
            cacheTTL: 7 * 24 * 3600,
            trust: .high
        ),
        NeedsSourceDescriptor(
            id: .internetArchive,
            displayName: "Internet Archive",
            role: "Short + long texts; librivoxaudio gap signal",
            guaranteed: false,
            defaultTimeout: NeedsDiscoveryConstants.rungTimeout,
            cacheTTL: 7 * 24 * 3600,
            trust: .high
        ),
        NeedsSourceDescriptor(
            id: .wikisource,
            displayName: "Wikisource",
            role: "Short works and the monthly featured text",
            guaranteed: false,
            defaultTimeout: NeedsDiscoveryConstants.rungTimeout,
            cacheTTL: 7 * 24 * 3600,
            trust: .medium
        ),
        NeedsSourceDescriptor(
            id: .libriVoxForum,
            displayName: "LibriVox Forum",
            role: "Live open projects, proof-listener needs, and the weekly poem",
            guaranteed: false,
            defaultTimeout: NeedsDiscoveryConstants.rungTimeout,
            cacheTTL: 6 * 3600,
            trust: .low
        )
    ]

    public static func descriptor(for id: NeedSourceID) -> NeedsSourceDescriptor {
        all.first { $0.id == id }!
    }

    /// Per-source `User-Agent` sent with every request (§9 politeness).
    public static func userAgent(for id: NeedSourceID) -> String {
        "Voxglass/1.1 (narration-needs; contact: hello@parso.guru)"
    }
}
