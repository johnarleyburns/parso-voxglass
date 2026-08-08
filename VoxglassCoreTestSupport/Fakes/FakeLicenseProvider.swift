import Foundation
import VoxglassCore

/// A recording `LicenseProvider` for tests (§19.2).
///
/// Every protocol access is appended to `calls` so a test can prove the free
/// export path never consults the gate. `failEveryCall` makes every throwing
/// operation throw, and `failNext(_:)` injects a one-shot failure for a
/// deterministic error path.
public final class FakeLicenseProvider: LicenseProvider, @unchecked Sendable {
    public enum Access: Sendable, Equatable {
        case entitlement
        case refresh
        case purchase
        case restore
        case product
    }

    private let lock = NSLock()
    private var state: EntitlementState
    private var info: ProductInfo
    private var failEveryCall: Bool
    private var failNextWith: LicenseError?
    private var recorded: [Access] = []

    private let continuation: AsyncStream<EntitlementState>.Continuation
    public let updates: AsyncStream<EntitlementState>

    public init(
        entitlement: EntitlementState = .free,
        productInfo: ProductInfo = ProductInfo(
            displayPrice: "$79.00",
            displayName: NarrationProProduct.displayName,
            description: "Professional retail delivery"
        ),
        failEveryCall: Bool = false
    ) {
        var c: AsyncStream<EntitlementState>.Continuation!
        let stream = AsyncStream<EntitlementState> { c = $0 }
        self.continuation = c
        self.updates = stream
        self.state = entitlement
        self.info = productInfo
        self.failEveryCall = failEveryCall
        self.failNextWith = nil
    }

    /// All accesses recorded so far, in order.
    public var calls: [Access] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The current entitlement (test writes drive the recorded `updates`).
    public func setEntitlement(_ newState: EntitlementState) {
        lock.lock()
        state = newState
        lock.unlock()
        continuation.yield(newState)
    }

    /// Make the next throwing call fail with `error`.
    public func failNext(_ error: LicenseError) {
        lock.lock()
        failNextWith = error
        lock.unlock()
    }

    public var entitlement: EntitlementState {
        get async {
            record(.entitlement)
            return currentState()
        }
    }

    public func refresh() async {
        record(.refresh)
    }

    public func purchasePro() async throws -> EntitlementState {
        record(.purchase)
        try consumeFailure()
        return currentState()
    }

    public func restore() async throws -> EntitlementState {
        record(.restore)
        try consumeFailure()
        return currentState()
    }

    public func product() async throws -> ProductInfo {
        record(.product)
        try consumeFailure()
        return currentInfo()
    }

    // MARK: - Internals

    private func record(_ access: Access) {
        lock.lock()
        recorded.append(access)
        lock.unlock()
    }

    private func currentState() -> EntitlementState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func currentInfo() -> ProductInfo {
        lock.lock()
        defer { lock.unlock() }
        return info
    }

    private func consumeFailure() throws {
        lock.lock()
        defer { lock.unlock() }
        if failEveryCall {
            throw LicenseError.purchaseFailed("forced failure")
        }
        if let error = failNextWith {
            failNextWith = nil
            throw error
        }
    }
}
