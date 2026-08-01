import Foundation
import Observation
import VoxglassCore

/// Production home (mockup 02): the selected project's progress, review counts, and
/// the entry points that start review queues.
@MainActor
@Observable
public final class WatchProductionHomeModel {

    public let summary: ProjectSummary
    public var hasActiveQueue = false

    private let environment: ProductionWatchEnvironment

    public init(summary: ProjectSummary, environment: ProductionWatchEnvironment) {
        self.summary = summary
        self.environment = environment
        self.hasActiveQueue = environment.activeQueue?.projectID == summary.id
    }

    public var flaggedCount: Int { summary.flaggedCount }
    public var pickupCount: Int { summary.needsPickupCount }
    public var unapprovedCount: Int { summary.unapprovedCount }

    public func startFlagged() {
        environment.startFlaggedReview()
    }

    public func startPickup() {
        // The phone relays a pickup queue on request; in MVP the flagged queue is
        // the one that is always available.
        environment.startFlaggedReview()
    }
}
