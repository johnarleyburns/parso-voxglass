import SwiftUI
import VoxglassCore

/// Production home (mockup 02): hero, Continue, flagged/pickup entry points, chapters
/// and sync rows. Pushed inside the tab's single NavigationStack; navigation uses
/// `NavigationLink(value:)`.
struct ProductionHomeView: View {
    @Environment(ProductionWatchEnvironment.self) private var env
    @Bindable private var model: WatchProductionHomeModel

    init(model: WatchProductionHomeModel) {
        _model = Bindable(model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                CoverInitialsView(text: initials, size: 64)
                Text(model.summary.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("\(Int(model.summary.percentRecorded))% recorded")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink(value: ProductionRoute.review) {
                    Label("Continue", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(ProductionWatchAccessibility.continueButton)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { model.startFlagged() })

                HStack(spacing: 8) {
                    NavigationLink(value: ProductionRoute.review) {
                        VStack(spacing: 2) {
                            Image(systemName: "flag.fill")
                            Text("Flagged")
                            Text("\(model.flaggedCount)")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(ProductionWatchAccessibility.reviewFlagged)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { model.startFlagged() })

                    NavigationLink(value: ProductionRoute.reviewQueues) {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Pickups")
                            Text("\(model.pickupCount)")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .contentShape(Rectangle())
                }

                NavigationLink(value: ProductionRoute.reviewQueues) {
                    Label("Review Queues", systemImage: "list.bullet")
                }
                .accessibilityIdentifier(ProductionWatchAccessibility.reviewQueues)
                .contentShape(Rectangle())

                NavigationLink(value: ProductionRoute.syncStatus) {
                    Label("Sync Status", systemImage: "arrow.triangle.2.circlepath.circle")
                }
                .contentShape(Rectangle())

                if !env.isReachable {
                    Text("iPhone not reachable. Your review actions are saved and will sync.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.yellow)
                        .padding(.top, 4)
                }
            }
            .padding()
        }
        .navigationTitle(model.summary.title)
    }

    private var initials: String {
        let words = model.summary.title.split(separator: " ")
        let picked = words.prefix(2).compactMap { $0.first }
        return String(picked).uppercased()
    }
}
