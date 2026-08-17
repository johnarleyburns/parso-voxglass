import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxglassCore

/// The Record tab (spec §18.1.7, mockup `06-recording-workspace`): takes list,
/// teleprompter + meter, quality panel, input level chip, and the full §11.4
/// keyboard table via a local key monitor.
struct RecordTabView: View {
    let project: AudiobookProject

    @Environment(StudioEnvironment.self) private var env
    @State private var model: RecordingModel?
    @State private var paragraphIndex = 0
    @State private var showImport = false
    @State private var localKeyMonitor: Any?
    @State private var isMonitoring = false
    @State private var showMicExplanation = false
    @State private var showMicDenied = false
    @AppStorage("voxglass.micExplanationSeen") private var micExplanationSeen = false

    private var paragraphs: [Paragraph] { project.allParagraphs }

    var body: some View {
        if let model {
            HStack(spacing: 0) {
                takesColumn(model)
                Divider()
                VStack(spacing: 0) {
                    RecordingWorkspaceView(
                        model: model,
                        paragraph: paragraphs.isEmpty ? nil : paragraphs[paragraphIndex],
                        paragraphIndex: paragraphIndex,
                        totalParagraphs: paragraphs.count,
                        onAccept: { Task { await model.acceptAndAdvance(advanceTo: navigate) } },
                        onNavigate: { index in
                            let clamped = max(0, min(index, paragraphs.count - 1))
                            paragraphIndex = clamped
                            Task { await model.loadParagraph(paragraphs[clamped].id) }
                        }
                    )
                    qualityAndLevelBar(model)
                }
            }
            .frame(minWidth: 1000, minHeight: 560)
            .task {
                model.settings = env.settings.settings
                await model.loadProject()
                if let first = paragraphs.first {
                    await model.loadParagraph(first.id)
                }
                if !micExplanationSeen {
                    showMicExplanation = true
                }
            }
            .onAppear {
                installKeyMonitor(model)
                wireInterruptions(model)
            }
            .onDisappear { removeKeyMonitor() }
            .onChange(of: model.captureError) {
                if model.captureError == .permissionDenied {
                    showMicDenied = true
                }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result {
                    Task { await model.importWAV(at: url) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioRecordParagraph)) { note in
                if let id = note.object as? UUID, let index = paragraphs.firstIndex(where: { $0.id == id }) {
                    paragraphIndex = index
                    Task { await model.loadParagraph(id) }
                    env.selectedTab = .record
                }
            }
            .background(Color.clear.onReceive(
                NotificationCenter.default.publisher(for: .studioRecordParagraphAdvance)
            ) { notification in
                let delta = (notification.object as? Int) ?? 1
                let clamped = max(0, min(paragraphIndex + delta, paragraphs.count - 1))
                paragraphIndex = clamped
                Task { await model.loadParagraph(paragraphs[clamped].id) }
            })
            .safeAreaInset(edge: .bottom) {
                if let banner = model.interruptionBanner {
                    interruptionBanner(banner, model: model)
                }
            }
            .sheet(isPresented: $showMicExplanation) {
                microphoneExplanationSheet(model: model)
            }
            .sheet(isPresented: $showMicDenied) {
                microphoneDeniedSheet(model: model)
            }
        }
    }

    // MARK: - Microphone permission (§18.5, mockup `17`)

    private func microphoneExplanationSheet(model: RecordingModel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Voxglass records your narration")
                .font(.title2.weight(.semibold))
            Text("Audio stays on your Mac unless you choose to preview it on your devices. Nothing is ever uploaded.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Continue") {
                micExplanationSeen = true
                showMicExplanation = false
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("record.micExplanationContinue")
        }
        .padding(30)
        .frame(width: 460)
    }

    private func microphoneDeniedSheet(model: RecordingModel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Microphone access is off")
                .font(.title2.weight(.semibold))
            Text("Voxglass needs microphone access to record. Open System Settings → Privacy & Security → Microphone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    showMicDenied = false
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("record.micDeniedOpenSettings")
                Button("Close") {
                    showMicDenied = false
                }
                .accessibilityIdentifier("record.micDeniedClose")
            }
        }
        .padding(30)
        .frame(width: 460)
    }

    // MARK: - Interruption banner (mockup `17`)

    private func interruptionBanner(_ banner: CaptureInterruptionBanner, model: RecordingModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let takeID = banner.takeID {
                Button("Reveal Take") {
                    Task { await model.selectTake(takeID) }
                    model.dismissInterruptionBanner()
                }
                .accessibilityIdentifier("record.interruption.revealTake")
            }
            Button("Resume Recording") {
                Task { await model.resumeAfterInterruption() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("record.interruption.resume")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func wireInterruptions(_ model: RecordingModel) {
        guard let capture = env.capture as? AVAudioEngineCapture else { return }
        capture.onInterruption = { @Sendable interruption in
            Task { @MainActor in
                await model.handleCaptureInterruption(interruption)
            }
        }
    }

    // MARK: - Takes column (§18.1.7 record.take.<n>)

    private func takesColumn(_ model: RecordingModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Takes")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.currentParagraphTakes.enumerated()), id: \.element.id) { index, take in
                        takeRow(model, take, index: index)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button {
                    showImport = true
                } label: {
                    Label("Import WAV", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("record.importWAV")
                Spacer()
                if model.isComputingQuality {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(minWidth: 240, idealWidth: 280)
        .background(.bar.opacity(0.5))
    }

    private func takeRow(_ model: RecordingModel, _ take: Take, index: Int) -> some View {
        let isSelected = model.selectedTakeID == take.id
        return HStack(spacing: 8) {
            Button(action: { Task { await model.selectTake(take.id) } }) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Take \(index + 1)")
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        HStack(spacing: 6) {
                            Text(String(format: "%.1fs", take.duration))
                                .font(.caption2)
                                .monospacedDigit()
                            qualityFlags(model.metrics(for: take.id))
                        }
                    }
                    Spacer()
                    if take.isArchived {
                        Image(systemName: "archivebox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record.take.\(index)")
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func qualityFlags(_ metrics: AudioQualityMetrics?) -> some View {
        if let metrics {
            HStack(spacing: 4) {
                if metrics.clipCount > 0 {
                    Label("clipped", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if metrics.peakDBFS > -3 {
                    Label("hot", systemImage: "flame")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
        }
    }

    // MARK: - Quality panel + input level chip

    private func qualityAndLevelBar(_ model: RecordingModel) -> some View {
        HStack(spacing: 16) {
            if let metrics = model.metrics(for: model.selectedTakeID ?? UUID()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quality")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Peak \(String(format: "%.1f", metrics.peakDBFS)) dB")
                            .font(.caption)
                            .monospacedDigit()
                            .accessibilityIdentifier("record.quality.peak")
                        Text("Noise \(String(format: "%.0f", metrics.noiseFloorDBFS)) dB")
                            .font(.caption)
                            .monospacedDigit()
                            .accessibilityIdentifier("record.quality.noise")
                        if metrics.clipCount > 0 {
                            Text("\(metrics.clipCount) clipped samples")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Spacer()
            InputLevelChip(meter: model.meter)
                .accessibilityIdentifier("record.inputLevel")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - §11.4 keyboard monitor

    private func installKeyMonitor(_ model: RecordingModel) {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event, model: model)
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent, model: RecordingModel) {
        guard let characters = event.charactersIgnoringModifiers else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])

        switch (characters, flags) {
        case (" ", []):
            Task {
                if model.canRecord {
                    await model.startRecording(paragraphID: paragraphs[paragraphIndex].id)
                } else {
                    await model.stopRecording()
                }
            }
        case ("\r", []):
            Task { await model.acceptAndAdvance(advanceTo: navigate) }
        case ("\r", .command):
            Task { await model.flagAndAdvance(advanceTo: navigate) }
        case ("r", []), ("R", []):
            Task { await model.retake() }
        case ("\u{7f}", .command):  // ⌘⌫
            Task { await model.archiveCurrentTake() }
        case ("\u{3}", .option):    // ⌥Space
            Task { await model.playSelectedTake() }
        case (" ", .shift):         // ⇧Space
            Task { await model.playInContext() }
        case ("p", []), ("P", []):
            Task {
                if isMonitoring { await model.stopMonitoring() } else { await model.startMonitoring() }
                isMonitoring.toggle()
            }
        case (_, []) where characters.allSatisfy(\.isNumber) && characters.count == 1:
            if let n = Int(characters), n >= 1, n <= 9, n <= model.currentParagraphTakes.count {
                let takeID = model.currentParagraphTakes[n - 1].id
                Task { await model.selectTake(takeID) }
            }
        case ("\u{f703}", []), ("\u{f702}", []):  // ← →
            let delta = characters == "\u{f703}" ? 1 : -1
            let clamped = max(0, min(paragraphIndex + delta, paragraphs.count - 1))
            paragraphIndex = clamped
            Task { await model.loadParagraph(paragraphs[clamped].id) }
        default:
            break
        }
    }

    private func navigate(_ id: UUID?) {
        if let id, let index = paragraphs.firstIndex(where: { $0.id == id }) {
            paragraphIndex = index
        }
    }
}

/// The input level chip reads `RecordingMeter` only — never `RecordingModel`
/// (spec §11.3; `PerformanceBudgetTests.teleprompterDoesNotInvalidateWhileMeterUpdates`).
private struct InputLevelChip: View {
    let meter: RecordingMeter

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic")
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.1f dB", meter.peakDBFS))
                    .font(.caption)
                    .monospacedDigit()
                Text(meter.isClipping ? "clipping" : "input")
                    .font(.caption2)
                    .foregroundStyle(meter.isClipping ? .red : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}
