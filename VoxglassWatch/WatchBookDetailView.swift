import SwiftUI
import VoxglassWatchProtocol

struct WatchBookDetailView: View {
    let book: WatchBookDTO
    @EnvironmentObject private var services: WatchAppServices
    @State private var showNowPlaying = false
    var body: some View {
        List {
            Section { Text(book.title).font(.headline); Text(book.author ?? "").font(.caption).foregroundStyle(.secondary); Button { services.play(book); showNowPlaying = true } label: { Label("Play", systemImage: "play.fill") }.accessibilityIdentifier("watch.book.play") }
            Section("Chapters") { ForEach(book.chapters, id: \.id) { chapter in Button { services.play(book, chapterIndex: chapter.index) } label: { Text(chapter.title) }.accessibilityIdentifier("watch.chapter.\(chapter.id.rawValue)") } }
            if services.isConnected { Section { if services.downloaded.contains(book.id) { Button("Remove from Apple Watch", role: .destructive) { services.remove(book) }.accessibilityIdentifier("watch.book.remove") } else { Button("Download to Apple Watch") { services.download(book) }.accessibilityIdentifier("watch.book.download") } } }
        }.navigationTitle("Book").navigationDestination(isPresented: $showNowPlaying) { WatchNowPlayingView() }
    }
}
