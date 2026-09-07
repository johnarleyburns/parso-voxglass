import AVFoundation
import SwiftUI
import VoxglassCore

/// "Mic Check" — record a few seconds through the real capture, watch a live
/// loudness waveform and a coarse frequency-band display while talking, then
/// hear the actual recording played back. Deliberately NOT a live pass-through
/// monitor (feedback-howl risk through the speaker); the user explicitly
/// chose "record then play back" over live monitoring.
/// Identifiers: `micCheck.start`, `micCheck.stopAndPlay`.
struct MicCheckView: View {
    let capture: any AudioCapturing
    @Environment(\.dismiss) private var dismiss

    @State private var isRecording = false
    @State private var isPlayingBack = false
    @State private var errorText: String?
    @State private var waveformHistory: [Float] = []
    @State private var currentBands: [Float] = []
    @State private var levelTask: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    @State private var pendingTakeURL: URL?

    /// Rolling window length for the waveform strip.
    private static let waveformHistoryLimit = 60
    /// Safety cap so a forgotten mic check doesn't record indefinitely.
    private static let maxRecordingSeconds: TimeInterval = 60

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    instructionCard
                    waveformCard
                    bandsCard
                    if let errorText {
                        Text(errorText)
                            .scaledFont(size: 12)
                            .foregroundStyle(Palette.danger)
                    }
                    actionButton
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Mic Check")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onDisappear {
            levelTask?.cancel()
            player?.stop()
            if isRecording {
                Task { await capture.cancelRecording() }
            }
            if let pendingTakeURL {
                try? FileManager.default.removeItem(at: pendingTakeURL)
            }
        }
    }

    // MARK: - Cards

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mic check")
                .scaledFont(size: 15, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text(statusText)
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink2)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private var statusText: String {
        if isPlayingBack { return "Playing back what was just recorded…" }
        if isRecording { return "Talk for a few seconds, then stop to hear the recording back." }
        return "Tap Start, talk for a few seconds, then stop to hear the recording back — a quick way to check your mic before recording for real."
    }

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loudness")
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.ink3)
            MicCheckWaveform(history: waveformHistory)
                .frame(height: 64)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private var bandsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frequency response")
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.ink3)
            MicCheckBands(bands: currentBands)
                .frame(height: 64)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private var actionButton: some View {
        Button {
            if isRecording {
                Task { await stopAndPlayBack() }
            } else {
                start()
            }
        } label: {
            Text(isRecording ? "Stop & Play Back" : "Start Mic Check")
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.brass)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.brass.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isPlayingBack)
        .accessibilityIdentifier(isRecording ? "micCheck.stopAndPlay" : "micCheck.start")
    }

    // MARK: - Recording

    private func start() {
        errorText = nil
        waveformHistory = []
        currentBands = []
        isRecording = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-check-\(UUID().uuidString).wav")
        pendingTakeURL = url
        Task {
            do {
                try await capture.prepare(device: nil, format: RecordingDefaults())
                try await capture.startRecording(to: url)
                startLevelSubscription()
            } catch {
                errorText = "The mic check couldn't start. \(error.localizedDescription)"
                isRecording = false
                pendingTakeURL = nil
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func startLevelSubscription() {
        levelTask?.cancel()
        levelTask = Task {
            for await levels in capture.levels {
                guard !Task.isCancelled else { return }
                waveformHistory.append(levels.peakDBFS)
                if waveformHistory.count > Self.waveformHistoryLimit {
                    waveformHistory.removeFirst(waveformHistory.count - Self.waveformHistoryLimit)
                }
                if !levels.bandMagnitudesDB.isEmpty {
                    currentBands = levels.bandMagnitudesDB
                }
                if levels.sampleTime >= Self.maxRecordingSeconds {
                    await stopAndPlayBack()
                    return
                }
            }
        }
    }

    private func stopAndPlayBack() async {
        guard isRecording else { return }
        isRecording = false
        levelTask?.cancel()
        levelTask = nil
        do {
            let take = try await capture.stopRecording()
            pendingTakeURL = nil
            playBack(take)
        } catch {
            errorText = "Couldn't finish the mic check. \(error.localizedDescription)"
            if let pendingTakeURL {
                try? FileManager.default.removeItem(at: pendingTakeURL)
            }
            pendingTakeURL = nil
        }
    }

    private func playBack(_ take: CapturedTake) {
        do {
            let player = try AVAudioPlayer(contentsOf: take.fileURL)
            self.player = player
            isPlayingBack = true
            player.play()
            let waitSeconds = max(take.duration, player.duration) + 0.3
            Task {
                try? await Task.sleep(for: .seconds(waitSeconds))
                isPlayingBack = false
                self.player = nil
                try? FileManager.default.removeItem(at: take.fileURL)
            }
        } catch {
            errorText = "Recorded, but playback failed. \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: take.fileURL)
        }
    }
}

/// A small scrolling bar-strip of recent peak-loudness samples (dB, mapped
/// onto a -60...0 dBFS range). Not a sample-accurate waveform — this is a
/// coarse, per-block loudness trace, which is what a mic check needs.
private struct MicCheckWaveform: View {
    let history: [Float]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(Palette.brass)
                        .frame(height: max(2, CGFloat(Self.fraction(for: value)) * proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }

    private static func fraction(for dB: Float) -> Float {
        max(0, min(1, (dB + 60) / 60))
    }
}

/// A live 8-bar frequency display driven by the capture's Goertzel-derived
/// band magnitudes — an approximate "EQ meter" look, not a precise analyzer.
private struct MicCheckBands: View {
    let bands: [Float]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.brass)
                        .frame(height: max(2, CGFloat(Self.fraction(for: value)) * proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }

    private static func fraction(for dB: Float) -> Float {
        max(0, min(1, (dB + 60) / 60))
    }
}
