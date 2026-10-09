import SwiftUI

/// Abbreviated counterpart to the iPhone app's About screen (Settings ›
/// About Voxglass) — a brief summary of what the watch app itself does
/// (nothing about the phone-only catalog/search features), the license, and
/// version info. Kept short: this is a watch screen, not the full iPhone page.
struct WatchAboutView: View {
    @EnvironmentObject private var services: WatchAppServices
    @State private var confirmReset = false
    @AppStorage(WatchSessionAdapter.resetKey) private var resetPending = false
    var body: some View {
        List {
            Section {
                Text("Voxglass plays audiobooks downloaded from your iPhone directly on your wrist — no phone nearby required once a book is on the watch.")
                    .font(.caption)
            }
            Section("License") {
                Text("Free software, GNU GPLv3+. Full source is public.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Version") {
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset watch listening data", role: .destructive) { confirmReset = true }
                    .disabled(resetPending)
                if resetPending { Text("Close and reopen Voxglass on this watch to finish reset.").font(.caption2) }
            }
        }
        .navigationTitle("About")
        .accessibilityIdentifier("watch.about")
        .confirmationDialog("Reset watch listening data?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { services.persistPlaybackPosition(); resetPending = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes watch audiobooks, artwork, and local listening settings on next launch. Your iPhone originals and unsubmitted narration review events are kept.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
