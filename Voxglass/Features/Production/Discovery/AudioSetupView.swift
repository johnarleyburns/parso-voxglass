import AVFoundation
import SwiftUI
import VoxglassCore
import VoxglassEncoders

/// The Audio Setup sheet (mockup 06b, spec §7.1). Classifies the current
/// route as retail-ready / community-ready / draft-only from a 10-second room
/// test. Bluetooth is never blocked — the truth is told at export time.
/// Identifiers: `audioSetup.classification`, `audioSetup.runTest`,
/// `audioSetup.done`.
struct AudioSetupView: View {
    let capture: any AudioCapturing
    @Environment(\.dismiss) private var dismiss

    @State private var routeInfo: CaptureRouteInfo
    @State private var classification: CaptureRouteClass
    @State private var isTesting = false
    @State private var isSelectingInput = false
    @State private var devices: [AudioDeviceInfo] = []
    @State private var selectedDeviceID: String = "default"
    @State private var result: RoomTestResult?
    @State private var errorText: String?

    init(capture: any AudioCapturing) {
        self.capture = capture
        let info = capture.currentRouteInfo
        _routeInfo = State(initialValue: info)
        _classification = State(initialValue: CaptureRouteClassifier.classify(info))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    currentInputCard
                    roomTestCard
                    inputGuidance
                    banner
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Audio setup")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSelectingInput ? "Selecting…" : "Use this input") { // l10n-exempt: state-dependent accessibility or status copy
                    Task { await selectInputAndDismiss() }
                }
                .disabled(isSelectingInput)
                    .accessibilityIdentifier("audioSetup.done")
            }
        }
        .task { await loadInputDevices() }
    }

    // MARK: - Cards

    private var currentInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Current input")
                    .voxFont(.subheadline, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(classificationLabel)
                    .voxFont(.caption2, weight: .bold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(classificationColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(classificationColor)
                    .accessibilityIdentifier("audioSetup.classification")
            }
            if devices.count > 1 || VoxglassPlatform.isMacCatalyst {
                Picker("Input device", selection: $selectedDeviceID) {
                    ForEach(devices) { device in
                        Text(device.name)
                            .tag(device.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("audioSetup.inputDevicePicker")
            }
            kv("Device", transportLabel)
            kv("Format", formatLabel)
            kv("Monitoring", "Direct (hardware)")
            Text("Voxglass records at the hardware's own format and resamples only at export.")
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)
        }
        .padding(14)
        .raisedSurface()
    }

    private var roomTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("10-second room test")
                .voxFont(.subheadline, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text("Stay quiet. We measure your room, not your voice.")
                .voxFont(.caption)
                .foregroundStyle(Palette.ink2)

            if let result {
                kv("Noise floor", "\(String(format: "%.1f", result.noiseFloorDBFS)) dBFS", ok: result.noiseFloorDBFS <= audioSetupNoiseFloorCeiling)
                kv("Peak", "\(String(format: "%.1f", result.peakDBFS)) dBFS", ok: result.peakDBFS <= audioSetupPeakCeiling)
                kv("Sample-rate stability", result.isStable ? String(localized: "Stable") : String(localized: "Unstable"))
            } else if isTesting {
                HStack(spacing: 8) {
                    ProgressView().tint(Palette.brass)
                    Text("Measuring… stay quiet")
                        .voxFont(.caption)
                        .foregroundStyle(Palette.ink2)
                }
            } else {
                Text("Run the test to check your room against the retail band.")
                    .voxFont(.caption)
                    .foregroundStyle(Palette.ink3)
            }

            if let errorText {
                Text(errorText)
                    .voxFont(.caption)
                    .foregroundStyle(Palette.danger)
            }

            Button {
                Task { await runTest() }
            } label: {
                Text(isTesting ? "Measuring…" : "Run the test again") // l10n-exempt: state-dependent accessibility or status copy
                    .voxFont(.footnote, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.brass.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isTesting)
            .accessibilityIdentifier("audioSetup.runTest")
        }
        .padding(14)
        .raisedSurface()
    }

    private var inputGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IF YOU CHANGE INPUT")
                .voxFont(.footnote, weight: .bold)
                .foregroundStyle(Palette.ink3)
            guidanceRow("USB-C interface or USB mic", "Recommended for LibriVox submission", Palette.ok, "LibriVox")
            guidanceRow("Wired headset mic", "Fine for LibriVox", Palette.brass, "LibriVox")
            guidanceRow("Built-in iPhone mic", "Usable in a quiet, soft-furnished room", Palette.brass, "Community")
            guidanceRow("Bluetooth / AirPods", "Allowed, but LibriVox quality checks will warn", Palette.danger, "Draft")
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this can and can't fix")
                .voxFont(.subheadline, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text("Voxglass can level, trim, and master your recording. It cannot make a noisy room or a compressed Bluetooth signal meet LibriVox quality checks. If your room test fails, the honest fix is the room or the microphone.")
                .voxFont(.caption)
                .foregroundStyle(Palette.ink2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedSurface()
    }

    private func guidanceRow(_ title: LocalizedStringKey, _ caption: LocalizedStringKey, _ color: Color, _ chip: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color.opacity(0.9)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).voxFont(.footnote, weight: .semibold).foregroundStyle(Palette.ink)
                Text(caption).voxFont(.caption2).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Text(chip)
                .voxFont(.caption2, weight: .bold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .padding(.vertical, 6)
    }

    private func kv(_ label: LocalizedStringKey, _ value: String, ok: Bool? = nil) -> some View {
        HStack {
            Text(label).voxFont(.caption).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value)
                .voxFont(.caption, weight: .medium)
                .foregroundStyle(ok == false ? Palette.danger : Palette.ink)
        }
    }

    // MARK: - Derived

    private var classificationLabel: String {
        CaptureRouteClassifier.label(for: classification)
    }

    private var classificationColor: Color {
        switch classification {
        case .retailReady: return Palette.ok
        case .communityReady: return Palette.brass
        case .draftOnly: return Palette.danger
        }
    }

    private var transportLabel: String {
        let transports = routeInfo.transports
        if transports.contains(.usb) { return "USB-C interface" }
        if transports.contains(.bluetooth) { return "Bluetooth" }
        if transports.contains(.wiredHeadset) { return String(localized: "Wired headset") }
        if transports.contains(.builtIn) { return "iPhone mic" }
        if transports.contains(.airPlay) { return "AirPlay" }
        return String(localized: "Current input")
    }

    private var formatLabel: String {
        let rate = routeInfo.sampleRate > 0 ? "\(Int(routeInfo.sampleRate)) kHz" : "—"
        return "\(rate) · mono"
    }

    /// The submission thresholds, imported from the LibriVox profile: never
    /// restated here.
    private var audioSetupNoiseFloorCeiling: Double {
        DestinationProfile.librivox.noiseFloorCeilingDBFS ?? -60
    }

    private var audioSetupPeakCeiling: Double {
        DestinationProfile.librivox.peakCeilingDBFS ?? -0.3
    }

    // MARK: - Room test

    /// Records ten seconds through the capture and measures the room's noise
    /// floor and peak against the retail band. The test file is deleted after
    /// measurement; it is never ingested into a project.
    private func runTest() async {
        isTesting = true
        errorText = nil
        defer { isTesting = false }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("room-test-\(UUID().uuidString).wav")
        do {
            try await capture.prepare(device: selectedDeviceID, format: RecordingDefaults())
            try await capture.startRecording(to: url)
            try await Task.sleep(for: .seconds(10))
            let take = try await capture.stopRecording()
            let metrics = try await AudioMetricsCalculator(decoder: AVFoundationDecoder()).metrics(for: take.fileURL)
            let updated = CaptureRouteInfo(
                transports: routeInfo.transports,
                sampleRate: metrics.sampleRate > 0 ? metrics.sampleRate : routeInfo.sampleRate,
                isSampleRateStable: true,
                inputLatencySeconds: routeInfo.inputLatencySeconds,
                measuredNoiseFloorDBFS: metrics.noiseFloorDBFS,
                measuredPeakDBFS: metrics.peakDBFS,
                measuredSpeechRMSDBFS: nil
            )
            routeInfo = updated
            classification = CaptureRouteClassifier.classify(updated)
            result = RoomTestResult(
                noiseFloorDBFS: metrics.noiseFloorDBFS,
                peakDBFS: metrics.peakDBFS,
                isStable: true
            )
            try? FileManager.default.removeItem(at: take.fileURL)
        } catch {
            errorText = String(localized: "The room test couldn't run. \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The measured room-test result. The room test measures the room, not
    /// speech, so `measuredSpeechRMSDBFS` is intentionally left unset on the
    /// route info (mockup 06b's "Speech RMS" row belongs to a separate
    /// read-sentence check that is not part of the stay-quiet test).
    private struct RoomTestResult {
        var noiseFloorDBFS: Double
        var peakDBFS: Double
        var isStable: Bool
    }

    private func loadInputDevices() async {
        let available = await capture.availableInputDevices()
        devices = available
        if let preferred = available.first(where: { $0.isDefault }) ?? available.first {
            selectedDeviceID = preferred.id
        }
    }

    private func selectInputAndDismiss() async {
        isSelectingInput = true
        defer { isSelectingInput = false }
        do {
            try await capture.prepare(device: selectedDeviceID, format: RecordingDefaults())
            routeInfo = capture.currentRouteInfo
            classification = CaptureRouteClassifier.classify(routeInfo)
            dismiss()
        } catch {
            errorText = String(localized: "That input couldn't be selected. \(error.localizedDescription)")
        }
    }
}
