import Foundation

/// Host-testable ownership for a projected CarPlay connection. The scene
/// delegate uses the generation as a capability: work from an older
/// connection can finish, but it can never mutate the current session.
public struct CarPlayConnectionStateMachine: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case consumer
        case production
    }

    public enum State: Sendable, Equatable {
        case disconnected
        case connecting(generation: Int)
        case connected(generation: Int, mode: Mode)
    }

    public private(set) var state: State = .disconnected
    private var nextGeneration = 0

    public init() {}

    @discardableResult
    public mutating func connect() -> Int {
        nextGeneration += 1
        state = .connecting(generation: nextGeneration)
        return nextGeneration
    }

    @discardableResult
    public mutating func finishConnect(generation: Int, mode: Mode) -> Bool {
        guard case .connecting(generation) = state else { return false }
        state = .connected(generation: generation, mode: mode)
        return true
    }

    public mutating func disconnect() {
        nextGeneration += 1
        state = .disconnected
    }

    public func owns(_ generation: Int) -> Bool {
        switch state {
        case .connecting(let current), .connected(let current, _):
            return current == generation
        case .disconnected:
            return false
        }
    }
}
