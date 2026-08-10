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
                Button("Use this input") { dismiss() }
                    .accessibilityIdentifier("audioSetup.done")
            }
        }
    }

    // MARK: - Cards

    private var currentInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Current input")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(classificationLabel)
                    .scaledFont(size: 11, weight: .bold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(classificationColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(classificationColor)
                    .accessibilityIdentifier("audioSetup.classification")
            }
            kv("Device", transportLabel)
            kv("Format", formatLabel)
            kv("Monitoring", "Direct (hardware)")
            Text("Voxglass records at the hardware's own format and resamples only at export.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private var roomTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("10-second room test")
                .scaledFont(size: 15, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text("Stay quiet. We measure your room, not your voice.")
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink2)

            if let result {
                kv("Noise floor", "\(String(format: "%.1f", result.noiseFloorDBFS)) dBFS", ok: result.noiseFloorDBFS <= audioSetupNoiseFloorCeiling)
                kv("Peak", "\(String(format: "%.1f", result.peakDBFS)) dBFS", ok: result.peakDBFS <= audioSetupPeakCeiling)
                kv("Sample-rate stability", result.isStable ? "Stable" : "Unstable")
            } else if isTesting {
                HStack(spacing: 8) {
                    ProgressView().tint(Palette.brass)
                    Text("Measuring… stay quiet")
                        .scaledFont(size: 12)
                        .foregroundStyle(Palette.ink2)
                }
            } else {
                Text("Run the test to check your room against the retail band.")
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.ink3)
            }

            if let errorText {
                Text(errorText)
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.danger)
            }

            Button {
                Task { await runTest() }
            } label: {
                Text(isTesting ? "Measuring…" : "Run the test again")
                    .scaledFont(size: 13, weight: .bold)
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
        .glassSurface(cornerRadius: 16)
    }

    private var inputGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IF YOU CHANGE INPUT")
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.ink3)
            guidanceRow("USB-C interface or USB mic", "Recommended for commercial release", Palette.ok, "Retail")
            guidanceRow("Wired headset mic", "Fine for LibriVox and Internet Archive", Palette.brass, "Community")
            guidanceRow("Built-in iPhone mic", "Usable in a quiet, soft-furnished room", Palette.brass, "Community")
            guidanceRow("Bluetooth / AirPods", "Allowed, but retail export will warn", Palette.danger, "Draft")
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this can and can't fix")
                .scaledFont(size: 15, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text("Voxglass can level, trim, and master your recording. It cannot make a noisy room or a compressed Bluetooth signal meet ACX. If your room test fails, the honest fix is the room or the microphone.")
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 16)
    }

    private func guidanceRow(_ title: String, _ caption: String, _ color: Color, _ chip: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color.opacity(0.9)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                Text(caption).scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Text(chip)
                .scaledFont(size: 10, weight: .bold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .padding(.vertical, 6)
    }

    private func kv(_ label: String, _ value: String, ok: Bool? = nil) -> some View {
        HStack {
            Text(label).scaledFont(size: 12.5).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value)
                .scaledFont(size: 12.5, weight: .medium)
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
        if transports.contains(.wiredHeadset) { return "Wired headset" }
        if transports.contains(.builtIn) { return "iPhone mic" }
        if transports.contains(.airPlay) { return "AirPlay" }
        return "Current input"
    }

    private var formatLabel: String {
        let rate = routeInfo.sampleRate > 0 ? "\(Int(routeInfo.sampleRate)) kHz" : "—"
        return "\(rate) · mono"
    }

    /// The retail thresholds, imported from the ACX profile (§3): never
    /// restated here.
    private var audioSetupNoiseFloorCeiling: Double {
        DestinationProfile.acx.noiseFloorCeilingDBFS ?? -60
    }

    private var audioSetupPeakCeiling: Double {
        DestinationProfile.acx.peakCeilingDBFS ?? -3
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
            try await capture.prepare(device: nil, format: RecordingDefaults())
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
            errorText = "The room test couldn't run. \(error.localizedDescription)"
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
}
