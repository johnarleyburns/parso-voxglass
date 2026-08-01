import SwiftUI
import VoxglassCore

/// Paragraph text (mockup 05): the current script, the current note, dictated-note
/// entry, and Approve/Pickup.
struct WatchParagraphTextView: View {
    @Environment(ProductionWatchEnvironment.self) private var env

    var body: some View {
        if let review = env.review {
            content(review)
        } else {
            Text("No active review queue.")
                .foregroundStyle(.secondary)
        }
    }

    private func content(_ review: WatchReviewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(review.currentText ?? "")
                    .font(.footnote)
                    .lineSpacing(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier(ProductionWatchAccessibility.paragraphText)

                if let note = review.currentNote {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current note")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.footnote)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                NavigationLink(value: ProductionRoute.dictation) {
                    Label("Add Dictated Note", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(ProductionWatchAccessibility.dictate)
                .contentShape(Rectangle())

                HStack(spacing: 8) {
                    Button {
                        Task { await review.approve() }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerApprove)
                    .contentShape(Rectangle())

                    Button {
                        Task { await review.needsPickup() }
                    } label: {
                        Label("Pickup", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerPickup)
                    .contentShape(Rectangle())
                }
            }
            .padding()
        }
        .navigationTitle("Paragraph")
    }
}
