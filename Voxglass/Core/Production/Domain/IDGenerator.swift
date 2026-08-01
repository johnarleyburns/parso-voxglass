import Foundation

public protocol IDGenerator: Sendable {
    func next() -> UUID
}

public struct UUIDGenerator: IDGenerator {
    public init() {}
    public func next() -> UUID { UUID() } // determinism-exempt: canonical system implementation
}
