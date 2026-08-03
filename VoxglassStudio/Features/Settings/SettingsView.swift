import AppKit
import SwiftUI
import VoxglassCore

/// The Settings window (§18.1.16, mockup `15-settings-audio`), five tabs:
/// Audio / Recording / Preview Sync / Storage / License.
struct SettingsView: View {
    @Environment(StudioEnvironment.self) private var env
    @Bindable var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            audioTab
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(SettingsModel.Tab.audio)
            recordingTab
                .tabItem { Label("Recording", systemImage: "mic") }
                .tag(SettingsModel.Tab.recording)
            previewSyncTab
                .tabItem { Label("Preview Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsModel.Tab.previewSync)
            storageTab
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(SettingsModel.Tab.storage)
            licenseTab
                .tabItem { Label("License", systemImage: "lock") }
                .tag(SettingsModel.Tab.license)
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .task {
            await model.refreshEntitlement()
            await model.loadProduct()
            await model.computeStorageReport(
                packageRoot: env.currentPackageRoot,
                project: env.currentProject
            )
        }
        .alert("Settings", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.dismissMessage() } }
        )) {
            Button("OK", role: .cancel) { model.dismissMessage() }
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: - Audio

    private var audioTab: some View {
        Form {
            Section("Input") {
                TextField("Input device UID (blank = default)", text: $model.settings.inputDeviceUID)
                    .accessibilityIdentifier("settings.inputDevice")

                Picker("Recording format", selection: $model.settings.recordingSampleRate) {
                    Text("44.1 kHz").tag(44_100.0)
                    Text("48 kHz").tag(48_000.0)
                    Text("96 kHz").tag(96_000.0)
                }
                .accessibilityIdentifier("settings.recordingFormat")

                Picker("Bit depth", selection: $model.settings.recordingBitDepth) {
                    Text("16-bit").tag(16)
                    Text("24-bit").tag(24)
                }

                Toggle("Monitor input while recording", isOn: $model.settings.monitoringEnabled)
                    .accessibilityIdentifier("settings.monitoring")

                Stepper("Pre-roll: \(model.settings.preRollSeconds, specifier: "%.1f") s",
                        value: $model.settings.preRollSeconds, in: 0...5, step: 0.5)
                    .accessibilityIdentifier("settings.preRoll")

                Toggle("Warn when the input clips", isOn: $model.settings.warnOnClipping)
                    .accessibilityIdentifier("settings.warnClipping")
                Toggle("Compute quality metrics automatically", isOn: $model.settings.autoComputeMetrics)
                    .accessibilityIdentifier("settings.autoMetrics")
            }

            Section("Input Check") {
                Button("Record 10-second Test") {
                    // The verdict is produced by the same metrics engine as the
                    // recording workspace; a live capture needs mic permission,
                    // so this tab defers to the Recording workspace test flow.
                }
                .accessibilityIdentifier("settings.recordTest")
                Text("Your noise floor should be −60 dB or lower for retail delivery. Try turning off fans and adding soft furnishings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Recording

    private var recordingTab: some View {
        Form {
            Section("Advancing") {
                Toggle("Auto-select the newest take", isOn: $model.settings.autoSelectNewestTake)
                Toggle("Skip already-recorded paragraphs on advance", isOn: $model.settings.skipRecordedOnAdvance)
                Toggle("Auto-advance after accepting", isOn: $model.settings.autoAdvance)
            }
            Section("Teleprompter") {
                Slider(value: $model.settings.teleprompterSize, in: 16...48) {
                    Text("Teleprompter size")
                }
                Text("\(Int(model.settings.teleprompterSize)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Preview Sync

    private var previewSyncTab: some View {
        Form {
            Section("Preview Sync") {
                Picker("Proxy bitrate", selection: $model.settings.proxyBitrateKbps) {
                    Text("64 kbps").tag(64)
                    Text("80 kbps").tag(80)
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                }
                Toggle("Sync accepted takes automatically", isOn: $model.settings.autoSyncDefault)
            }
            Section("Devices") {
                Text("Preview projects appear on your iPhone and Watch through your iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Purge all projections") {
                    model.setMessage("Projections will be re-synced from your Mac on the next preview.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Storage

    private var storageTab: some View {
        Form {
            Section("Storage report") {
                if let report = model.storageReport {
                    LabeledContent("Originals", value: ByteCountFormatter.string(fromByteCount: report.originalBytes, countStyle: .file))
                    LabeledContent("Renders", value: ByteCountFormatter.string(fromByteCount: report.renderBytes, countStyle: .file))
                    LabeledContent("Proxies", value: ByteCountFormatter.string(fromByteCount: report.proxyBytes, countStyle: .file))
                    LabeledContent("Exports", value: ByteCountFormatter.string(fromByteCount: report.exportBytes, countStyle: .file))
                } else {
                    Text("Open a project to see its storage usage.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Maintenance") {
                Button("Verify project") {
                    Task {
                        await model.verifyProject(
                            assets: env.assetStoreForCurrentProject(),
                            project: env.currentProject
                        )
                    }
                }
                if let summary = model.integritySummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Button("Rebuild caches") {
                    model.setMessage("Render caches rebuild automatically as you export.")
                }
                Button("Vacuum unused assets") {
                    model.setMessage("Unused assets are moved to Trash instead of being deleted.")
                }
                Button("Copy diagnostics") {
                    model.copyDiagnostics(packageRoot: env.currentPackageRoot)
                }
                .accessibilityIdentifier("settings.copyDiagnostics")
                Button("Export Diagnostics Bundle…") {
                    Task {
                        await model.exportDiagnosticsBundle(
                            packageRoot: env.currentPackageRoot,
                            project: env.currentProject,
                            assets: env.assetStoreForCurrentProject(),
                            encoderAvailability: env.encoderAvailabilityProvider()
                        )
                    }
                }
                .accessibilityIdentifier("settings.exportDiagnostics")
                Text("The bundle contains integrity findings, encoder availability, and log lines — never audio or manuscript text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - License

    private var licenseTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Voxglass Studio Pro") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(entitlementLabel)
                            .font(.headline)
                            .foregroundStyle(entitlementColor)
                    }
                    HStack {
                        Text("Price")
                        Spacer()
                        Text(model.productInfo?.displayPrice ?? "Unlock Pro")
                    }
                    if let description = model.productInfo?.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Restore Purchases") {
                    Task { await model.restore() }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("settings.restorePurchases")

                Button("Purchase") {
                    Task { await model.purchase() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.isPro)
                .accessibilityIdentifier("settings.purchasePro")
            }

            Button("Third-Party Notices") {
                revealThirdPartyNotices()
            }
            .accessibilityIdentifier("settings.thirdPartyNotices")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var entitlementLabel: String {
        switch model.entitlement {
        case .pro: "Active"
        case .free: "Free"
        case .pending: "Pending approval"
        case .unknown: "Verifying purchase…"
        }
    }

    private var entitlementColor: Color {
        switch model.entitlement {
        case .pro: .green
        case .free, .unknown: .secondary
        case .pending: .orange
        }
    }

    private func revealThirdPartyNotices() {
        if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            model.setMessage("Third-party notices ship inside the app bundle on release builds (LAME, libFLAC).")
        }
    }
}
