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
                    artwork
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let narrator = book.narrator, !narrator.isEmpty {
                        Text("Read by \(narrator)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                        Text(chapter.title).lineLimit(1)
                    }
                    .accessibilityIdentifier("watch.chapter.\(chapter.id.rawValue)")
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
            .accessibilityLabel(isCurrentBook && playback.isActuallyPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("watch.book.play")
            Button { services.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                .frame(width: 44, height: 44)
                .disabled(!isCurrentBook || !playback.canGoNext)
                .accessibilityLabel("Next chapter")
                .accessibilityIdentifier("watch.book.nextChapter")
        }
        .frame(maxWidth: .infinity)
    }

    /// Status/progress detail — only meaningful once this book is actually
    /// the one loaded into the engine.
    private var nowPlayingDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let currentChapterTitle {
                Text(currentChapterTitle).font(.caption).lineLimit(1)
                    .accessibilityIdentifier("watch.book.currentChapter")
            }
            Text(playback.statusText).font(.caption2).foregroundStyle(statusColor).lineLimit(2)
                .accessibilityIdentifier("watch.book.phase")
            if indeterminateProgress {
                ProgressView().accessibilityIdentifier("watch.book.progress")
            } else {
                ProgressView(value: playback.progress).accessibilityIdentifier("watch.book.progress")
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
            if case .failed = playback.phase {
                Button("Retry") { services.retryPlayback() }.accessibilityIdentifier("watch.book.retry")
            }
        }
    }

    private var currentChapterTitle: String? {
        guard playback.chapterIndex >= 0, book.chapters.indices.contains(playback.chapterIndex) else { return nil }
        let chapter = book.chapters[playback.chapterIndex]
        return "Chapter \(playback.chapterIndex + 1) of \(book.chapters.count): \(chapter.title)"
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
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
