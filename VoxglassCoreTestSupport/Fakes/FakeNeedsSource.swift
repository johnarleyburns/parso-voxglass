import Foundation
import VoxglassCore

/// Deterministic `NeedsSource` fake: returns fixed needs, or fails with a
/// fixed error. Never touches the network. Optionally counts invocations so
/// tests can prove the circuit breaker skips a flapping rung.
public final class FakeNeedsSource: NeedsSource, @unchecked Sendable {
    public let id: NeedSourceID
    public let needs: [NarrationNeed]
    public let fetchError: HTTPFetchError?
    private let lock = NSLock()
    public private(set) var fetchCount = 0

    public init(id: NeedSourceID, needs: [NarrationNeed] = [], fetchError: HTTPFetchError? = nil) {
        self.id = id
        self.needs = needs
        self.fetchError = fetchError
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        lock.withLock { fetchCount += 1 }
        if let fetchError {
            throw fetchError
        }
        return needs
    }

    public var callCount: Int {
        lock.withLock { fetchCount }
    }
}
