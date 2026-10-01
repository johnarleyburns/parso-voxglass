import SwiftUI
import VoxglassWatchCore
import VoxglassWatchProtocol

/// Watch redesign §5 B1/B2 — the page for a book that isn't playing. Cover, title, author,
/// narrator; one big button that says exactly what happens ("Resume · Ch 3 · 0:51", "Start", or
/// "Download · 412 MB"); then Chapters and the download state. Starting playback pushes the Player
/// in the same tap — never a second screen that needs a second tap.
struct WatchBookPageView: View {
    let book: WatchBookDTO
    @Binding var path: [WatchRoute]
    @EnvironmentObject private var services: WatchAppServices
    @State private var confirmRemove = false

    private var isDownloaded: Bool { services.downloaded.contains(book.id) }

    var body: some View {
        List {
            header.listRowBackground(Color.clear)
            Section {
                primaryButton
                // B2: streaming is offered honestly, right under Download.
                if !isDownloaded, services.isConnected, canStream {
                    Button { start(at: 0) } label: { Label("Stream Chapter 1", systemImage: "play.fill") }
                        .buttonStyle(.watchSecondarySmall)
                        .accessibilityIdentifier("watch.book.stream")
                }
                HStack(spacing: 6) {
                    Button { path.append(.chapters(book.id)) } label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                    .buttonStyle(.watchSecondarySmall)
                    .disabled(!canPlay)
                    .accessibilityIdentifier("watch.book.chaptersButton")
                    downloadStateButton
                }
                if !isDownloaded && !services.isConnected {
                    Text("Not on this watch. Bring your iPhone nearby to stream or download it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationTitle("")
        .confirmationDialog("Remove from Apple Watch?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { services.stopDownload(book) }
                .accessibilityIdentifier("watch.book.remove")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your place is kept. You can download it again from your iPhone.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            WatchCoverTile(artworkKey: book.artworkKey, width: 40)
                .accessibilityIdentifier("watch.book.artwork")
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(3)
                    .accessibilityIdentifier("watch.book.title")
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.caption2).foregroundStyle(.secondary)
                }
                if let narrator = book.narrator, !narrator.isEmpty {
                    Text("Read by \(narrator)").font(.caption2).foregroundStyle(.secondary)
                } else if book.duration > 0 {
                    Text(WatchTimeFormat.short(book.duration)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canStream: Bool { book.chapters.first?.approvedStreamURL != nil }
    private var canPlay: Bool { isDownloaded || (services.isConnected && canStream) }

    @ViewBuilder
    private var primaryButton: some View {
        if isDownloaded || (services.isConnected && canStream && services.resumePosition(for: book) != nil) {
            Button { start(at: services.resumeChapterIndex(for: book)) } label: {
                Label(resumeTitle, systemImage: "play.fill")
            }
            .buttonStyle(.watchPrimary)
            .accessibilityIdentifier("watch.book.start")
        } else if services.isConnected {
            if let download = services.downloads[book.id] {
                HStack(spacing: 8) {
                    WatchTransferRing(fraction: download.total > 0 ? download.fraction : nil)
                    Text("Downloading \(download.done) of \(download.total)").font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("watch.book.downloading")
            } else {
                Button { services.download(book) } label: {
                    Label(downloadTitle, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.watchPrimary)
                .accessibilityIdentifier("watch.book.download")
            }
        } else {
            Button {} label: { Text("Not on This Watch") }
                .buttonStyle(.watchSecondary)
                .disabled(true)
        }
    }

    @ViewBuilder
    private var downloadStateButton: some View {
        if isDownloaded {
            Button { confirmRemove = true } label: {
                Label("On Watch", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.watchSecondarySmall)
            .foregroundStyle(WatchPalette.success)
            .accessibilityIdentifier("watch.book.onWatch")
        } else if services.isConnected, services.downloads[book.id] == nil,
                  services.resumePosition(for: book) != nil {
            Button { services.download(book) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.watchSecondarySmall)
            .accessibilityIdentifier("watch.book.download")
        }
    }

    private var resumeTitle: String {
        guard let position = services.resumePosition(for: book), position > 1 || services.resumeChapterIndex(for: book) > 0 else {
            return String(localized: "Start")
        }
        let chapter = services.resumeChapterIndex(for: book) + 1
        return String(localized: "Resume · Ch \(chapter) · \(WatchTimeFormat.clock(position))")
    }

    private var downloadTitle: String {
        let bytes = book.chapters.compactMap(\.expectedBytes).reduce(0, +)
        guard bytes > 0 else { return String(localized: "Download") }
        return String(localized: "Download · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
    }

    private func start(at chapterIndex: Int) {
        services.play(book, chapterIndex: chapterIndex)
        path.append(.player)
    }
}
