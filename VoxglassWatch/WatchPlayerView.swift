import AVFoundation
import SwiftUI
import WatchKit
import VoxglassWatchCore
import VoxglassWatchProtocol

/// Watch redesign §5 P1–P3, S1–S3, A1, A3 — one fixed player face made for spoken audio. Chapter
/// title over book title, a chapter hairline with times (tap to toggle chapter / book remaining at
/// the current speed), back 15 · play · forward 30, and a toolbar of Chapters · Speed · Sleep ·
/// Output. The Crown is volume. Failures replace the transport with a Problem Card in place.
struct WatchPlayerView: View {
    @EnvironmentObject private var services: WatchAppServices
    @Binding var path: [WatchRoute]
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var crownVolume = 1.0
    @State private var showingOutput = false
    @State private var outputName: String?

    private var playback: WatchPlaybackSnapshot { services.playback }
    private var book: WatchBookDTO? { services.playbackBook }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 4) {
                // S3: a Problem Card replaces the whole face — no chip or titles around it.
                if !isFailed { chips }
                if let book {
                    if !isFailed { titles(book) }
                    content(book)
                } else {
                    Text("Nothing playing").font(.headline).foregroundStyle(.secondary).padding(.top, 20)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            // The back button and the clock share the top row; the output chip gets its own row
            // below them (mockup P1).
            .padding(.top, 8)
        }
        .focusable(!isLuminanceReduced)
        .digitalCrownRotation($crownVolume, from: 0, through: 1, by: 0.05, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownVolume) { _, value in services.setVolume(value) }
        .onAppear {
            crownVolume = services.volume
            refreshOutput()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            refreshOutput()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingOutput) { WatchOutputSheet(outputName: outputName) }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            // VoiceOver: swipe up/down skips forward 30 / back 15 (A3).
            services.skip(by: direction == .increment ? WatchSkip.forward : -WatchSkip.backward)
        }
    }

    // MARK: Background (cover tint)

    private var background: some View {
        RadialGradient(colors: [Color(red: 0.48, green: 0.35, blue: 0.18), Color(red: 0.16, green: 0.12, blue: 0.09), .black],
                       center: .top, startRadius: 0, endRadius: 210)
            .opacity(isLuminanceReduced ? 0.45 : 0.9)
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityIdentifier("watch.book.artwork")
            .accessibilityLabel(Text("Cover"))
    }

    // MARK: Chips: output (+ source) and sleep

    private var chips: some View {
        HStack(spacing: 4) {
            WatchTargetChip(systemImage: "headphones", title: outputTitle, tone: .onArtwork)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(outputName ?? String(localized: "No audio output")))
                .accessibilityValue(Text(sourceLabel ?? ""))
                .accessibilityIdentifier("watch.book.output")
            if let remaining = services.sleepRemaining, services.sleepTimer != nil {
                WatchTargetChip(systemImage: "moon.fill", title: WatchTimeFormat.short(remaining), tone: .neutral)
                    .accessibilityLabel(Text("Sleep timer, \(WatchTimeFormat.short(remaining)) left"))
                    .accessibilityIdentifier("watch.book.sleepChip")
            }
        }
    }

    private var outputTitle: String {
        let name = outputName ?? String(localized: "No output")
        if playback.sourceKind == .stream { return String(localized: "\(name) · streaming") }
        return name
    }

    private var sourceLabel: String? {
        switch playback.sourceKind {
        case .downloaded: String(localized: "Downloaded")
        case .stream: String(localized: "Streaming")
        case nil: nil
        }
    }

    private func refreshOutput() {
        outputName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }

    // MARK: Titles

    private func titles(_ book: WatchBookDTO) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // P1: the chapter title leads. The "Chapter N" caption appears only when the title
            // doesn't already say it.
            if !currentChapterTitle(book).localizedCaseInsensitiveContains("\(playback.chapterIndex + 1)") {
                Text("Chapter \(playback.chapterIndex + 1)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("watch.book.chapterNumber")
            }
            Text(currentChapterTitle(book))
                .font(.headline)
                .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)
                .accessibilityIdentifier("watch.book.currentChapter")
            if dynamicTypeSize < .accessibility1 {
                Text(book.title).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .accessibilityIdentifier("watch.book.title")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func currentChapterTitle(_ book: WatchBookDTO) -> String {
        guard book.chapters.indices.contains(playback.chapterIndex) else { return book.title }
        return book.chapters[playback.chapterIndex].title
    }

    // MARK: Content per state

    @ViewBuilder
    private func content(_ book: WatchBookDTO) -> some View {
        if case .failed(let message) = playback.phase {
            problemCard(message)
        } else if isLuminanceReduced {
            Text("\(WatchTimeFormat.short(max(0, playback.duration - playback.position))) left in chapter")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4).padding(.top, 8)
        } else {
            WatchProgressHairline(fraction: playback.progress)
                .padding(.horizontal, 4)
            if dynamicTypeSize < .accessibility1 { times(book) }
            transport
            // While audio plays the face is P1 (the rate is on the toolbar); any other state —
            // connecting, buffering, paused, waiting for output — is said in words here.
            if !playback.isActuallyPlaying {
                Text(statusLine)
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.book.phase")
            }
        }
    }

    /// P1: chapter times. (Book time left lives on Home and in the Smart Stack card; a tap target
    /// this small failed the hit-region audit.)
    private func times(_ book: WatchBookDTO) -> some View {
        HStack {
            Text(WatchTimeFormat.clock(playback.position)).accessibilityIdentifier("watch.book.elapsed")
            Spacer()
            Text(verbatim: "−\(WatchTimeFormat.clock(max(0, playback.duration - playback.position)))")
                .accessibilityIdentifier("watch.book.remaining")
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var transport: some View {
        HStack {
            WatchTransportButton(systemImage: "gobackward.15", label: Text("Back 15 seconds"),
                                 isEnabled: canTransport, diameterOverride: 40) {
                services.skip(by: -WatchSkip.backward)
            }
            .accessibilityIdentifier("watch.book.skipBack")
            Spacer(minLength: 4)
            WatchTransportButton(systemImage: playPauseSymbol,
                                 label: playback.isActuallyPlaying ? Text("Pause") : Text("Play"),
                                 role: .primary, isBusy: isBusy, diameterOverride: 50) {
                services.togglePlayPause()
            }
            .accessibilityIdentifier("watch.book.play")
            .accessibilityValue(Text(statusLine))
            .watchPrimaryActionShortcut()
            Spacer(minLength: 4)
            WatchTransportButton(systemImage: "goforward.30", label: Text("Forward 30 seconds"),
                                 isEnabled: canTransport, diameterOverride: 40) {
                services.skip(by: WatchSkip.forward)
            }
            .accessibilityIdentifier("watch.book.skipForward")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var playPauseSymbol: String {
        if playback.isActuallyPlaying { return "pause.fill" }
        return "play.fill"
    }

    private var canTransport: Bool {
        switch playback.phase {
        case .playing, .paused, .buffering: true
        default: false
        }
    }

    private var isBusy: Bool {
        switch playback.phase {
        case .preparing, .waitingForOutput, .buffering: true
        default: false
        }
    }

    private var statusLine: String {
        let speed = WatchSpeed.label(playback.rate)
        switch playback.phase {
        case .idle: return String(localized: "Ready")
        case .preparing: return String(localized: "Preparing…")
        case .waitingForOutput: return String(localized: "Connecting to headphones…")
        case .buffering: return String(localized: "Buffering…")
        case .playing: return String(localized: "Playing · \(speed)")
        case .paused: return String(localized: "Paused · \(speed)")
        case .ended: return String(localized: "Finished")
        case .failed(let message): return message
        }
    }

    // MARK: Problem Cards (S1–S3)

    @ViewBuilder
    private func problemCard(_ message: String) -> some View {
        switch playback.failureKind ?? .other {
        case .noOutput:
            WatchProblemCard(
                systemImage: "headphones", title: "Connect Headphones",
                message: String(localized: "Books play through Bluetooth headphones or speakers connected to this watch."),
                actions: [.init(title: "Choose Output", systemImage: "airplayaudio", identifier: "watch.book.retry") {
                    services.retryPlayback()
                }],
                code: playback.failureCode)
        case .chapterUnavailable:
            WatchProblemCard(
                systemImage: "iphone.slash", title: "Chapter Not on This Watch", message: message,
                actions: chapterUnavailableActions,
                code: playback.failureCode)
        case .stalled, .other:
            WatchProblemCard(
                systemImage: "exclamationmark.triangle", title: "Audio Didn't Start", message: message,
                actions: [.init(title: "Try Again", systemImage: "arrow.clockwise", identifier: "watch.book.retry") {
                    services.retryPlayback()
                }],
                code: playback.failureCode)
        }
    }

    private var chapterUnavailableActions: [WatchProblemCard.Action] {
        var actions: [WatchProblemCard.Action] = [
            .init(title: "Try Again", systemImage: "arrow.clockwise", identifier: "watch.book.retry") {
                services.retryPlayback()
            }
        ]
        if playback.chapterIndex > 0 {
            actions.append(.init(title: "Back to Chapter \(playback.chapterIndex)", isPrimary: false,
                                 identifier: "watch.book.previousAvailable") {
                services.previousChapter()
            })
        }
        return actions
    }

    private var isFailed: Bool {
        if case .failed = playback.phase { return true }
        return false
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // A Problem Card owns the screen's actions (S3); the tool row would cover them.
        if !isLuminanceReduced && !isFailed {
            ToolbarItemGroup(placement: .bottomBar) {
                tool(systemImage: "list.bullet", label: "Chapters", identifier: "watch.book.chapters") {
                    if let id = book?.id { path.append(.chapters(id)) }
                }
                Spacer()
                Button { path.append(.speed) } label: {
                    Text(verbatim: WatchSpeed.label(playback.rate))
                        .font(.caption2.weight(.bold))
                        .frame(width: WatchMetrics.toolButton, height: WatchMetrics.toolButton)
                        .background(Circle().fill(WatchPalette.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Speed \(WatchSpeed.label(playback.rate))"))
                .accessibilityIdentifier("watch.book.speed")
                Spacer()
                WatchToolButton(systemImage: "moon", label: Text("Sleep Timer"),
                                isOn: services.sleepTimer != nil) { path.append(.sleep) }
                    .accessibilityIdentifier("watch.book.sleep")
                Spacer()
                tool(systemImage: "airplayaudio", label: "Output", identifier: "watch.book.outputButton") {
                    showingOutput = true
                }
            }
        }
    }

    private func tool(systemImage: String, label: LocalizedStringKey, identifier: String,
                      action: @escaping () -> Void) -> some View {
        WatchToolButton(systemImage: systemImage, label: Text(label), action: action)
            .accessibilityIdentifier(identifier)
    }
}

/// Output (§5): watchOS has no route-picker view, so this hosts the system `NowPlayingView`, whose
/// AirPlay button switches the output.
struct WatchOutputSheet: View {
    let outputName: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                if let outputName {
                    Text("Now: \(outputName)").font(.caption2).foregroundStyle(.secondary)
                }
                NowPlayingView()
            }
            .navigationTitle(Text("Output"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
