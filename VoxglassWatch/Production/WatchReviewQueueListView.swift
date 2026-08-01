import SwiftUI
import VoxglassCore

/// Review queues (mockup 03): the available predicates with paragraph counts and
/// total duration. Tapping a row starts that queue and pushes the review player.
struct WatchReviewQueueListView: View {
    @Environment(ProductionWatchEnvironment.self) private var env

    var body: some View {
        List {
            NavigationLink(value: ProductionRoute.review) {
                queueRow(icon: "flag.fill", title: "Flagged", count: flaggedCount, duration: flaggedDuration)
            }
            .accessibilityIdentifier(ProductionWatchAccessibility.queue("flagged"))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { env.startFlaggedReview() })

            NavigationLink(value: ProductionRoute.review) {
                queueRow(icon: "arrow.triangle.2.circlepath", title: "Needs Pickup", count: pickupCount, duration: 0)
            }
            .accessibilityIdentifier(ProductionWatchAccessibility.queue("pickup"))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { env.startFlaggedReview() })

            NavigationLink(value: ProductionRoute.review) {
                queueRow(icon: "circle", title: "Unapproved", count: unapprovedCount, duration: 0)
            }
            .accessibilityIdentifier(ProductionWatchAccessibility.queue("unapproved"))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { env.startFlaggedReview() })
        }
        .navigationTitle("Review")
    }

    private var flaggedCount: Int { env.activeQueue?.paragraphIDs.count ?? 0 }
    private var pickupCount: Int { env.summaries.first?.needsPickupCount ?? 0 }
    private var unapprovedCount: Int { env.summaries.first?.unapprovedCount ?? 0 }
    private var flaggedDuration: TimeInterval {
        guard let queue = env.activeQueue else { return 0 }
        return queue.paragraphIDs.reduce(0) { total, id in total + (queue.durations[id] ?? 0) }
    }

    private func queueRow(
        icon: String,
        title: String,
        count: Int,
        duration: TimeInterval
    ) -> some View {
        HStack {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(count) paragraphs · \(WatchTimeFormat.duration(duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
