import Foundation

public struct WatchTransportFaults: Sendable, Equatable {
    public var delay: Duration = .zero; public var duplicateNext = false; public var reorder = false; public var failNext = false
    public init() {}
}

public actor WatchFakeDuplexLink {
    public let phone: WatchFakeDuplexTransport
    public let watch: WatchFakeDuplexTransport
    private var faults = WatchTransportFaults()
    private var reachable = true
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []

    public init() {
        phone = WatchFakeDuplexTransport(); watch = WatchFakeDuplexTransport()
        phone.link = self; watch.link = self
    }
    public func setReachable(_ value: Bool) { reachable = value; phone.reachable=value; watch.reachable=value }
    public func setFaults(_ value: WatchTransportFaults) { faults=value }
    fileprivate func deliver(_ data: Data) async throws {
        guard reachable else { throw WatchProtocolFault(.unreachable) }
        if faults.failNext { faults.failNext=false; throw WatchProtocolFault(.failed) }
        let copies = faults.duplicateNext ? 2 : 1; faults.duplicateNext=false
        if faults.delay != .zero { try await Task.sleep(for: faults.delay) }
        for _ in 0..<copies { enqueue(data) }
    }
    fileprivate func next() async -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
    private func enqueue(_ data: Data) {
        if let waiter = waiters.first { waiters.removeFirst(); waiter.resume(returning: data) }
        else if faults.reorder, let first = pending.first { pending[0]=data; pending.append(first) }
        else { pending.append(data) }
    }
}

public final class WatchFakeDuplexTransport: @unchecked Sendable, WatchDuplexTransport {
    fileprivate weak var link: WatchFakeDuplexLink?
    fileprivate var reachable = true
    public init() {}
    public var isReachable: Bool { get async { reachable } }
    public func send(_ data: Data, over channel: WatchTransportChannel) async throws {
        guard let link else { throw WatchProtocolFault(.failed) }
        try await link.deliver(data)
    }
    public func receive() async -> Data {
        guard let link else { return Data() }
        return await link.next()
    }
}

public actor WatchMessageLedger {
    private let limit: Int
    private var applied: [UUID] = []
    public init(limit: Int = 256) { self.limit = max(1, limit) }
    public func contains(_ id: UUID) -> Bool { applied.contains(id) }
    public func record(_ id: UUID) { guard !applied.contains(id) else { return }; applied.append(id); if applied.count > limit { applied.removeFirst(applied.count-limit) } }
    public func count() -> Int { applied.count }
}

public struct WatchConnectionReducer: Sendable, Equatable {
    public enum State: String, Codable, Sendable { case opening, connected, temporarilyUnavailable, unavailable }
    public private(set) var state: State = .opening
    public private(set) var lastReachabilityChange: Date?
    public var debounce: TimeInterval
    public init(debounce: TimeInterval = 2) { self.debounce=debounce }
    public mutating func activated(at date: Date) { state = .connected; lastReachabilityChange=date }
    public mutating func reachabilityChanged(_ reachable: Bool, at date: Date) {
        if reachable { state = .connected; lastReachabilityChange=date }
        else { state = .temporarilyUnavailable; lastReachabilityChange=date }
    }
    public mutating func tick(at date: Date) { if state == .temporarilyUnavailable, let changed=lastReachabilityChange, date.timeIntervalSince(changed) >= debounce { state = .unavailable } }
}

public actor WatchProtocolRouter {
    public let libraryID: WatchPairedLibraryID
    public let ledger: WatchMessageLedger
    private var latestRevision: Int64 = 0
    public init(libraryID: WatchPairedLibraryID, ledger: WatchMessageLedger = WatchMessageLedger()) { self.libraryID=libraryID; self.ledger=ledger }
    public func accept(_ data: Data) -> Result<WatchProtocolEnvelope, WatchProtocolFault> {
        guard let envelope = try? WatchProtocolEnvelope.decode(data) else { return .failure(.init(.malformed)) }
        guard envelope.pairedLibraryID == libraryID else { return .failure(.init(.wrongPair)) }
        if envelope.projectionRevision < latestRevision { return .failure(.init(.staleRevision)) }
        latestRevision = max(latestRevision, envelope.projectionRevision)
        return .success(envelope)
    }
    public func markApplied(_ id: UUID) async -> Bool { if await ledger.contains(id) { return false }; await ledger.record(id); return true }
}
