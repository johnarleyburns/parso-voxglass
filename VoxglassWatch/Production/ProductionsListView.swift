import SwiftUI
import VoxglassCore

/// Productions tab root (mockup 01): the list of productions the phone relayed. Owns
/// the single NavigationStack for the whole tab; every destination is registered here.
struct ProductionsListView: View {
    @Environment(ProductionWatchEnvironment.self) private var env
    @State private var model: WatchProductionsModel?

    var body: some View {
        NavigationStack {
            Group {
                if let summaries = model?.summaries, !summaries.isEmpty {
                    List(summaries) { summary in
                        NavigationLink(value: ProductionRoute.home(summary.id)) {
                            ProductionRowView(summary: summary, isCurrent: model?.isCurrent(summary) ?? false)
                        }
                        .accessibilityIdentifier(ProductionWatchAccessibility.productionRow(model?.slug(for: summary) ?? "production"))
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("No productions yet")
                            .font(.headline)
                        Text("Open iPhone to sync more projects")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .navigationTitle("My Productions")
            .navigationDestination(for: ProductionRoute.self) { route in
                destination(route)
            }
        }
        .task {
            if model == nil {
                model = WatchProductionsModel(environment: env)
            }
            await model?.load()
        }
    }

    @ViewBuilder
    private func destination(_ route: ProductionRoute) -> some View {
        switch route {
        case .home(let projectID):
            if let summary = env.summaries.first(where: { $0.id == projectID }) {
                ProductionHomeView(model: WatchProductionHomeModel(summary: summary, environment: env))
            } else {
                Text("Project not found")
            }
        case .reviewQueues:
            WatchReviewQueueListView()
        case .review:
            WatchReviewPlayerView()
        case .paragraphText:
            WatchParagraphTextView()
        case .dictation:
            WatchDictationCategoryView()
        case .syncStatus:
            WatchSyncStatusView()
        case .offlineQueue:
            WatchOfflineQueueView()
        }
    }
}

/// One production card: cover initials, title, flagged badge, progress bar.
struct ProductionRowView: View {
    let summary: ProjectSummary
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoverInitialsView(text: initials, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack {
                    if summary.flaggedCount > 0 {
                        Text("\(summary.flaggedCount) flagged")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.25), in: Capsule())
                    }
                    if isCurrent {
                        Text("Current")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: summary.percentRecorded, total: 100)
                    .tint(.blue)
                Text("\(Int(summary.percentRecorded))% recorded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var initials: String {
        let words = summary.title.split(separator: " ")
        let picked = words.prefix(2).compactMap { $0.first }
        return String(picked).uppercased()
    }
}

struct CoverInitialsView: View {
    let text: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [.purple.opacity(0.7), .indigo.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(text)
                .font(.system(size: size * 0.35, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size * 1.3)
    }
}
