import SwiftUI
import VoxglassCore

/// Watch sync status (mockup 09): relayed-from-iPhone state, storage, pending actions.
struct WatchSyncStatusView: View {
    @Environment(ProductionWatchEnvironment.self) private var env
    @State private var model: WatchSyncModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: env.isReachable ? "arrow.triangle.2.circlepath.circle.fill" : "icloud.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)

                Text(statusTitle)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Text(statusSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    row("Review audio", value: byteString)
                    row("Pending actions", value: "\(model?.pendingEventCount ?? env.pendingEventCount)")
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                Text("This Watch receives production data from the paired iPhone, not directly from iCloud.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("Sync")
        .accessibilityIdentifier(ProductionWatchAccessibility.syncStatus)
        .task {
            if model == nil { model = WatchSyncModel(environment: env) }
            model?.refresh()
        }
    }

    private var statusTitle: String {
        env.isReachable ? "Current with iPhone" : "iPhone not reachable"
    }

    private var statusColor: Color {
        env.isReachable ? .green : .yellow
    }

    private var statusSubtitle: String {
        guard let last = env.lastSyncAt else {
            return env.isReachable ? "Waiting for first sync" : "Actions are saved on Watch"
        }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        return "Updated \(max(1, minutes)) minute\(minutes == 1 ? "" : "s") ago"
    }

    private var byteString: String {
        WatchTimeFormat.bytes(Int64(env.audioStore.usedBytes))
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(env.pendingEventCount > 0 && title == "Pending actions" ? .orange : .primary)
        }
        .font(.footnote)
    }
}
