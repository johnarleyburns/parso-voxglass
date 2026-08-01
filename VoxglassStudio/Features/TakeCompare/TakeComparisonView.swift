import SwiftUI
import VoxglassCore

/// Spec §18.1.9 / mockup `08-take-comparison`: A/B with synchronized position,
/// per-take metrics, "Suggested" heuristic, "Use Selected Take".
struct TakeComparisonView: View {
    let model: TakeComparisonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            takeList
            if let error = model.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Compare Takes")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.takes.count) take(s) for this paragraph")
                .font(.headline)
            Text("The suggested take is a heuristic — it is never selected automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var takeList: some View {
        Table(model.takes) { [model] in
            TableColumn("Take") { take in
                HStack(spacing: 8) {
                    if take.id == model.recommendedTakeID {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .help("Suggested")
                    }
                    Text(shortID(take.id))
                        .monospacedDigit()
                    if take.id == model.selectedTakeID {
                        Text("Selected")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
            }
            TableColumn("Duration") { take in
                Text(String(format: "%.1f s", take.duration))
                    .monospacedDigit()
            }
            TableColumn("Peak") { take in
                Text(metricText(take.metrics?.peakDBFS))
                    .monospacedDigit()
            }
            TableColumn("RMS") { take in
                Text(metricText(take.metrics?.rmsDBFS))
                    .monospacedDigit()
            }
            TableColumn("Noise") { take in
                Text(metricText(take.metrics?.noiseFloorDBFS))
                    .monospacedDigit()
            }
            TableColumn("") { take in
                HStack(spacing: 12) {
                    Button("A/B Play") {
                        Task { await model.play(take.id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("takecompare.play.\(shortID(take.id))")
                    Button("Use Selected Take") {
                        Task { await model.select(take.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("takecompare.select.\(shortID(take.id))")
                }
            }
        }
        .frame(minHeight: 200)
    }

    private func metricText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f dB", value)
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
