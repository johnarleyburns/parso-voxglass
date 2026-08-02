import SwiftUI
import VoxglassCore

/// Device Preview (spec §13.8, mockup `12-device-preview`): sync status, per-device
/// state, "Automatically sync accepted takes", "Include source text", "Hide Project
/// from Devices", the watch offline queue, and the storage profile.
public struct DevicePreviewView: View {
    let model: DevicePreviewModel

    @Environment(StudioEnvironment.self) private var env

    public init(model: DevicePreviewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                syncStatusCard
                deviceCard
                Toggle(isOn: Binding(get: { model.autoSync }, set: { newValue in
                    Task { await model.updateAutoSync(newValue) }
                })) {
                    Text("Automatically sync accepted takes")
                }
                .accessibilityIdentifier("preview.autoSync")

                Toggle(isOn: Binding(get: { model.includeText }, set: { newValue in
                    Task { await model.updateIncludeText(newValue) }
                })) {
                    Text("Include source text")
                }
                .accessibilityIdentifier("preview.includeText")

                if let error = model.syncErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                watchCard
                storageCard
                feedbackCard
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("Device Preview")
        .onAppear {
            Task { await model.load() }
        }
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Status").font(.headline)
            HStack {
                statusDot
                Text(accountLabel)
                Spacer()
                Button("Sync Now") {
                    Task { await model.syncNow() }
                }
                .accessibilityIdentifier("preview.syncNow")
            }
            Text("Revision \(model.lastPublishedRevision ?? 0) · last synced \(model.lastSyncDate?.formatted(date: .abbreviated, time: .shortened) ?? "never")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private var statusDot: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }

    private var color: Color {
        switch model.accountStatus {
        case .available: return .green
        case .notAuthenticated, .quotaExceeded: return .orange
        case .unavailable: return .gray
        }
    }

    private var accountLabel: String {
        switch model.accountStatus {
        case .available: return "iPhone connected through iCloud"
        case .notAuthenticated: return "Sign in to iCloud to preview on your devices"
        case .quotaExceeded: return "iCloud storage is full — hide the project from devices or free space"
        case .unavailable: return "iCloud unavailable — everything else keeps working"
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices").font(.headline)
            row("iPhone", "Current through iCloud")
            row("Watch", "Relayed by iPhone")
            row("CarPlay", "Available")
            if !model.hideFromDevices {
                Button("Hide Project from Devices") {
                    Task { await model.toggleHide(true) }
                }
                .accessibilityIdentifier("preview.hideFromDevices")
            } else {
                Button("Show Project on Devices") {
                    Task { await model.toggleHide(false) }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func row(_ name: String, _ state: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(state).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var watchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Watch").font(.headline)
            HStack {
                Text("Offline review queue")
                Spacer()
                Text("\(model.watchQueueItemCount) items")
            }
            Button("Prepare Offline Queue") {
                Task { await model.prepareOfflineQueue() }
            }
            .disabled(model.watchQueueItemCount == 0)
            .accessibilityIdentifier("preview.prepareOfflineQueue")
            Text("The watch receives audio only through this iPhone; it never connects to CloudKit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage Profile").font(.headline)
            Picker("Proxy bitrate", selection: Binding(get: { model.proxyBitrateKbps }, set: { bitrate in
                Task { await model.updateBitrate(bitrate) }
            })) {
                ForEach([48, 64, 80, 128], id: \.self) { Text("\($0) kbps").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("preview.storageProfile")
            Text("Full project estimate: \(model.storageEstimateLabel)")
                .font(.callout)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pending Feedback").font(.headline)
            HStack {
                Text("\(model.pendingFeedbackCount) review actions from your devices")
                Spacer()
                Button("Open Review Queue") {
                    env.navigate(to: .review)
                }
                .accessibilityIdentifier("preview.openReviewQueue")
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }
}
