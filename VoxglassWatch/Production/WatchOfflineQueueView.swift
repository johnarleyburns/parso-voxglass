import SwiftUI
import VoxglassCore

/// Offline queue (mockup 10): how much of the flagged queue is downloaded and the
/// entry point to review with the phone powered off.
struct WatchOfflineQueueView: View {
    @Environment(ProductionWatchEnvironment.self) private var env

    private var paragraphCount: Int { env.activeQueue?.paragraphIDs.count ?? 0 }
    private var downloadedCount: Int {
        (env.activeQueue?.paragraphIDs ?? []).filter { env.audioStore.hasAudio(for: $0) }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("\(paragraphCount)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("flagged paragraphs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloaded")
                        Spacer()
                        Text("\(downloadedCount) of \(paragraphCount)")
                            .foregroundStyle(.green)
                            .fontWeight(.semibold)
                    }
                    .font(.footnote)
                    ProgressView(value: Double(downloadedCount), total: Double(max(paragraphCount, 1)))
                        .tint(.blue)
                    Text("\(WatchTimeFormat.bytes(Int64(env.audioStore.usedBytes))) · available without iPhone nearby")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                NavigationLink(value: ProductionRoute.review) {
                    Label("Start Offline Review", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadedCount == 0)
                .accessibilityIdentifier(ProductionWatchAccessibility.offlineStart)
                .contentShape(Rectangle())

                Button {
                    env.audioStore.clear()
                } label: {
                    Text("Remove Queue")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier(ProductionWatchAccessibility.offlineRemove)
                .contentShape(Rectangle())
            }
            .padding()
        }
        .navigationTitle("Offline Review")
    }
}
