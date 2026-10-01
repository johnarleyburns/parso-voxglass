import AVFoundation
import SwiftUI
import VoxglassWatchCore
import VoxglassWatchProtocol

/// One combined book + now-playing view. This used to be two separate
/// screens (book detail, then a second "Now Playing" screen reached only
/// after pressing Play) — reported as confusing on its own ("why are there
/// two separate views"), and the second screen required pressing Play a
/// second time to do anything. Everything — artwork, transport, progress,
/// and the chapter list — now lives in one place, matching the shape of the
/// iPhone app's own book page more closely than two disjoint watch screens
/// did.
struct WatchBookDetailView: View {
    let book: WatchBookDTO
    @EnvironmentObject private var services: WatchAppServices
    @State private var crownVolume = 1.0

    private var isCurrentBook: Bool { services.playbackBook?.id == book.id }
    private var playback: WatchPlaybackSnapshot { services.playback }
    private var currentChapterIndex: Int? { isCurrentBook ? playback.chapterIndex : nil }

    var body: some View {
        List {
            Section {
                // Left-justified, single column, top to bottom: title,
                // artwork, then author/narrator/duration — no side-by-side
                // HStack (that put the artwork's frame directly over the
                // title on watchOS's narrow width instead of leaving room
                // beside it).
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.headline).lineLimit(2).accessibilityIdentifier("watch.book.title")
                    artwork.accessibilityHidden(true)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let narrator = book.narrator, !narrator.isEmpty {
                        Text("Read by \(narrator)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !formattedDuration(book.duration).isEmpty {
                        Text(formattedDuration(book.duration)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                transportRow
                if isCurrentBook {
                    nowPlayingDetail
                }
            }
            Section("Chapters") {
                ForEach(book.chapters, id: \.id) { chapter in
                    Button {
                        services.play(book, chapterIndex: chapter.index)
                    } label: {
                        Text(chapter.title)
                    }
                    .accessibilityIdentifier("watch.chapter.\(chapter.id.rawValue)")
                    .accessibilityLabel("Chapter \(chapter.index + 1), \(chapter.title)")
                }
            }
            if services.isConnected {
                Section {
                    if services.downloaded.contains(book.id) {
                        Button("Remove from Apple Watch", role: .destructive) { services.remove(book) }
                            .accessibilityIdentifier("watch.book.remove")
                    } else {
                        Button("Download to Apple Watch") { services.download(book) }
                            .accessibilityIdentifier("watch.book.download")
                    }
                }
            }
        }
        .navigationTitle("")
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let url = book.artworkKey.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.blue.gradient)
                        .overlay { Image(systemName: "book.closed") }
                }
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.blue.gradient)
                    .overlay { Image(systemName: "book.closed") }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("watch.book.artwork")
    }

    /// The single play control: starts this book if nothing's loaded (or a
    /// different book is), toggles play/pause in place if this book is
    /// already the one loaded — never a second screen or a second tap.
    private var transportRow: some View {
        HStack(spacing: 2) {
            Button { services.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                .frame(width: 44, height: 44)
                .disabled(!isCurrentBook || !playback.canGoPrevious)
                .accessibilityLabel("Previous chapter")
                .accessibilityIdentifier("watch.book.previousChapter")
            Button {
                if isCurrentBook {
                    services.togglePlayPause()
                } else {
                    services.play(book, chapterIndex: currentChapterIndex ?? 0)
                }
            } label: {
                Image(systemName: isCurrentBook && playback.isActuallyPlaying ? "pause.fill" : "play.fill")
            }
            .frame(width: 44, height: 44)
            .disabled(isCurrentBook && transportBusy)
            .accessibilityLabel(isCurrentBook && playback.isActuallyPlaying ? "Pause" : "Play") // l10n-exempt: state-dependent accessibility or status copy
            .accessibilityIdentifier("watch.book.play")
            Button { services.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                .frame(width: 44, height: 44)
                .disabled(!isCurrentBook || !playback.canGoNext)
                .accessibilityLabel("Next chapter")
                .accessibilityIdentifier("watch.book.nextChapter")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls for \(book.title)")
    }

    /// Status/progress detail — only meaningful once this book is actually
    /// the one loaded into the engine.
    private var nowPlayingDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.caption).lineLimit(2)
                .accessibilityIdentifier("watch.nowPlaying.bookTitle")
            if let currentChapterTitle {
                Text(currentChapterTitle).font(.caption)
                    .accessibilityIdentifier("watch.book.currentChapter")
            }
            if playback.chapterIndex >= 0 {
                Text("Chapter \(playback.chapterIndex + 1)").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.book.chapterNumber")
            }
            if let sourceLabel {
                Text(sourceLabel).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.book.source")
            }
            // Which output the audio is actually routed to — a diagnostic
            // for the "Cannot Open"/silent-hang class of playback failures,
            // where the app appeared to work but nothing was audible because
            // no output route was connected.
            Text(outputRouteName).font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("watch.book.output")
            Text(playback.statusText).font(.caption2).foregroundStyle(statusColor)
                // A failure carries the diagnostic that says which step broke; never truncate it.
                .lineLimit(isFailed ? nil : 2)
                .fixedSize(horizontal: false, vertical: isFailed)
                .accessibilityIdentifier("watch.book.phase")
            if indeterminateProgress {
                ProgressView().accessibilityIdentifier("watch.book.progress")
            } else {
                ProgressView(value: playback.progress)
                    .accessibilityValue("\(Int(playback.progress * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        let delta: TimeInterval = 15
                        let newPos = direction == .increment ? playback.position + delta : playback.position - delta
                        services.seek(to: max(0, min(playback.duration, newPos)))
                    }
                    .accessibilityIdentifier("watch.book.progress")
            }
            HStack {
                Text(format(playback.position)).accessibilityIdentifier("watch.book.elapsed")
                Spacer()
                Text("−\(format(max(0, playback.duration - playback.position))) in chapter").accessibilityIdentifier("watch.book.remaining")
            }
            .font(.caption2).monospacedDigit()
            if book.duration > 0 {
                Text("\(formattedDuration(bookRemainingSeconds)) left in book").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.book.remainingInBook")
            }
            volumeControl
            if case .failed = playback.phase {
                Button("Retry") { services.retryPlayback() }.accessibilityIdentifier("watch.book.retry")
            }
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.1.fill")
                .accessibilityHidden(true)
            Text("Volume")
            Spacer()
            Text("\(Int((crownVolume * 100).rounded()))%")
                .monospacedDigit()
        }
        .focusable(true)
        .digitalCrownRotation(
            $crownVolume,
            from: 0,
            through: 1,
            by: 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownVolume) { _, value in services.setVolume(value) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((crownVolume * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: crownVolume = min(1, crownVolume + step)
            case .decrement: crownVolume = max(0, crownVolume - step)
            @unknown default: break
            }
            services.setVolume(crownVolume)
        }
        .accessibilityIdentifier("watch.book.volume")
    }

    private var sourceLabel: String? {
        switch playback.sourceKind {
        case .downloaded: String(localized: "Downloaded")
        case .stream: String(localized: "Streaming")
        case nil: nil
        }
    }

    private var outputRouteName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? String(localized: "No audio output")
    }

    private var currentChapterTitle: String? {
        guard playback.chapterIndex >= 0, book.chapters.indices.contains(playback.chapterIndex) else { return nil }
        let chapter = book.chapters[playback.chapterIndex]
        return String(localized: "Chapter \(playback.chapterIndex + 1) of \(book.chapters.count): \(chapter.title)")
    }

    /// Time left in the WHOLE book, not just the current chapter — the sum
    /// of every chapter still to come, plus what's left of this one.
    private var bookRemainingSeconds: TimeInterval {
        guard book.duration > 0, playback.chapterIndex >= 0 else { return 0 }
        let elapsedBeforeCurrentChapter = book.chapters.prefix(playback.chapterIndex).reduce(0) { $0 + $1.duration }
        let elapsedInBook = elapsedBeforeCurrentChapter + playback.position
        return max(0, book.duration - elapsedInBook)
    }

    private var transportBusy: Bool {
        switch playback.phase {
        case .idle, .preparing, .waitingForOutput: true
        default: false
        }
    }

    private var indeterminateProgress: Bool {
        switch playback.phase {
        case .idle, .preparing, .waitingForOutput, .buffering: true
        default: false
        }
    }

    private var isFailed: Bool {
        if case .failed = playback.phase { return true }
        return false
    }

    private var statusColor: Color {
        if case .failed = playback.phase { return .red }
        return .secondary
    }

    private func format(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        return Duration.seconds(Int64(seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
