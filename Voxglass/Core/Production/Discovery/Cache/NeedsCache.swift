import Foundation

/// Per-source cache state persisted across ladder runs (§9): last fetch/success
/// plus the circuit-breaker fields.
public struct NeedsSourceCacheState: Sendable, Codable, Equatable {
    public var lastFetch: Date?
    public var lastSuccess: Date?
    public var consecutiveFailures: Int
    public var openUntil: Date?

    public init(lastFetch: Date? = nil, lastSuccess: Date? = nil, consecutiveFailures: Int = 0, openUntil: Date? = nil) {
        self.lastFetch = lastFetch
        self.lastSuccess = lastSuccess
        self.consecutiveFailures = consecutiveFailures
        self.openUntil = openUntil
    }

    public init(breaker: CircuitBreaker, lastFetch: Date?, lastSuccess: Date?) {
        self.lastFetch = lastFetch
        self.lastSuccess = lastSuccess
        self.consecutiveFailures = breaker.consecutiveFailures
        self.openUntil = breaker.openUntil
    }
}

// MARK: - Caching protocol

/// Last-good persistence for discovery (NARRATION_NEEDS_SPEC §4.2, §9).
public protocol NeedsCaching: Sendable {
    func load() async -> NeedsSnapshot?
    func save(_ snapshot: NeedsSnapshot) async
    func state(for source: NeedSourceID) async -> NeedsSourceCacheState
    func setState(_ state: NeedsSourceCacheState, for source: NeedSourceID) async
}

// MARK: - In-memory (tests / previews)

public actor InMemoryNeedsCache: NeedsCaching {
    private var snapshot: NeedsSnapshot?
    private var states: [NeedSourceID: NeedsSourceCacheState] = [:]

    public init() {}

    public func load() async -> NeedsSnapshot? { snapshot }
    public func save(_ snapshot: NeedsSnapshot) async { self.snapshot = snapshot }
    public func state(for source: NeedSourceID) async -> NeedsSourceCacheState {
        states[source] ?? NeedsSourceCacheState()
    }
    public func setState(_ state: NeedsSourceCacheState, for source: NeedSourceID) async {
        states[source] = state
    }
}

// MARK: - File cache (actor, AppDatabase-style)

/// Persists the last-good merged snapshot plus per-source fetch/circuit-breaker
/// state as JSON (NARRATION_NEEDS_SPEC §9). The aggregator's first stream
/// element is `seed ∪ cache` — instant, before any network resolves.
public actor FileNeedsCache: NeedsCaching {
    private let url: URL
    private let clock: any Clock
    private var lastGood: NeedsSnapshot?
    private var sourceState: [NeedSourceID: NeedsSourceCacheState] = [:]

    private struct CacheFile: Codable {
        var version: Int
        var savedAt: Date
        var snapshot: NeedsSnapshot
        var sourceState: [String: NeedsSourceCacheState]
    }

    public init(url: URL, clock: any Clock) {
        self.url = url
        self.clock = clock
    }

    public func load() async -> NeedsSnapshot? {
        if let lastGood { return lastGood }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let file = try? NeedsJSONCoding.decoder.decode(CacheFile.self, from: data) else { return nil }
        lastGood = file.snapshot
        sourceState = Dictionary(uniqueKeysWithValues: file.sourceState.map { (NeedSourceID(rawValue: $0.key) ?? .seed, $0.value) })
        return lastGood
    }

    public func save(_ snapshot: NeedsSnapshot) async {
        lastGood = snapshot
        let file = CacheFile(
            version: 1,
            savedAt: clock.now,
            snapshot: snapshot,
            sourceState: Dictionary(uniqueKeysWithValues: sourceState.map { ($0.key.rawValue, $0.value) })
        )
        guard let data = try? NeedsJSONCoding.encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Per-source breaker state

    public func state(for source: NeedSourceID) async -> NeedsSourceCacheState {
        _ = await load()
        return sourceState[source] ?? NeedsSourceCacheState()
    }

    public func setState(_ state: NeedsSourceCacheState, for source: NeedSourceID) async {
        _ = await load() // don't clobber persisted state we haven't seen yet
        sourceState[source] = state
        if let lastGood {
            await save(lastGood)
        }
    }
}
