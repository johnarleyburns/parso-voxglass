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
