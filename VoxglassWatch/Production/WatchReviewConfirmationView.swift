import SwiftUI
import VoxglassCore

/// Review action confirmation (mockup 06). Presented as a **sheet** (never pushed
/// onto a NavigationPath) so the watch UI tests and VoiceOver get a distinct surface.
struct WatchReviewConfirmationView: View {
    private let review: WatchReviewModel

    init(review: WatchReviewModel) {
        self.review = review
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 8)

            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(color)

            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityIdentifier(identifier)

            Text("Paragraph saved on Watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let next = review.currentChapterLabel {
                Button {
                    Task { await review.playNext() }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Next \(review.payload.queueLabel.lowercased())")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(next)
                                .font(.footnote)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await review.playNext() }
            } label: {
                Label("Play Next", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(ProductionWatchAccessibility.playNext)
            .contentShape(Rectangle())

            Spacer(minLength: 8)
        }
        .padding()
        .accessibilityIdentifier(identifier)
    }

    private var title: String {
        switch review.confirmation {
        case .approved: "Approved"
        case .flagged: "Flagged"
        case .needsPickup: "Needs Pickup"
        case nil: ""
        }
    }

    private var icon: String {
        switch review.confirmation {
        case .approved: "checkmark.circle.fill"
        case .flagged: "flag.fill"
        case .needsPickup: "arrow.triangle.2.circlepath"
        case nil: "questionmark.circle"
        }
    }

    private var color: Color {
        switch review.confirmation {
        case .approved: .green
        case .flagged: .orange
        case .needsPickup: .yellow
        case nil: .gray
        }
    }

    private var identifier: String {
        switch review.confirmation {
        case .approved: ProductionWatchAccessibility.confirmationApproved
        case .flagged: ProductionWatchAccessibility.confirmationFlagged
        case .needsPickup: ProductionWatchAccessibility.confirmationPickup
        case nil: ""
        }
    }
}
