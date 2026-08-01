import Foundation
import VoxglassCore

public struct FixedClock: Clock, Sendable {
    public let now: Date

    public init(_ date: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.now = date
    }
}
