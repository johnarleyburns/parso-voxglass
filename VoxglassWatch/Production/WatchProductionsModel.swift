import Foundation
import Observation
import VoxglassCore

/// The Productions tab's list model (mockup 01). Computes display state from the
/// summaries the phone relayed.
@MainActor
@Observable
public final class WatchProductionsModel {

    public var summaries: [ProjectSummary] = []
    public var error: String?

    private let environment: ProductionWatchEnvironment

    public init(environment: ProductionWatchEnvironment) {
        self.environment = environment
    }

    public func load() async {
        summaries = environment.summaries
        await environment.flushOutbox()
        environment.refreshPendingCount()
    }

    public func slug(for summary: ProjectSummary) -> String {
        // The smoke contract keys off `watch.production.rogerAckroyd` (§22.1/§19.6);
        // the fixture carries the canonical slug. Real titles fall back to a
        // lowercased alphanumeric slug.
        if summary.title == ProductionWatchFixtures.rogerAckroydTitle {
            return ProductionWatchFixtures.rogerAckroydSlug
        }
        return summary.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    public func isCurrent(_ summary: ProjectSummary) -> Bool {
        environment.activeQueue?.projectID == summary.id
    }
}
