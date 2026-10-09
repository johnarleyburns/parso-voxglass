import SwiftUI
import VoxglassWatchCore
import VoxglassWatchProtocol

/// Installed audio only. Download and removal management live on the iPhone.
struct WatchBookPageView: View {
    let book: WatchBookDTO
    @Binding var path: [WatchRoute]
    @EnvironmentObject private var services: WatchAppServices
    private var isDownloaded: Bool { services.downloaded.contains(book.id) }

    var body: some View {
        List {
            Section {
                header
                Button {
                    services.play(book, chapterIndex: services.resumeChapterIndex(for: book))
                    path.append(.player)
                } label: { Label("Resume", systemImage: "play.fill") }
                .buttonStyle(.watchPrimary)
                .disabled(!isDownloaded)
                .accessibilityIdentifier("watch.book.start")
                Button { path.append(.chapters(book.id)) } label: { Label("Chapters", systemImage: "list.bullet") }
                    .buttonStyle(.watchSecondarySmall).disabled(!isDownloaded)
                    .accessibilityIdentifier("watch.book.chaptersButton")
                Label(isDownloaded ? String(localized: "On This Watch") : String(localized: "Send from your iPhone"), systemImage: "applewatch")
                    .font(.caption2).accessibilityIdentifier("watch.book.onWatch")
            }.listRowBackground(Color.clear)
        }.listStyle(.plain).navigationTitle("")
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

}
