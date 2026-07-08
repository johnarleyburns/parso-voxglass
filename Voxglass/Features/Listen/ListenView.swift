import SwiftUI

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VoxglassScreen(title: "Listen") {
            VStack(alignment: .leading, spacing: 22) {
                hero
                continueListening
                recentlyAdded
            }
            .padding(.top, 12)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("voxglass")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .foregroundStyle(VoxglassTheme.ink)
            Text("Public-domain audiobooks, private by default.")
                .font(.subheadline)
                .foregroundStyle(VoxglassTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var continueListening: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Continue Listening")
            if let session = playback.currentSession {
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 14) {
                        BookArtworkView(title: session.book.title, size: 70)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.book.title)
                                .font(.headline)
                                .foregroundStyle(VoxglassTheme.ink)
                                .lineLimit(2)
                            Text(session.chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(VoxglassTheme.secondaryInk)
                                .lineLimit(1)
                            ProgressView(value: session.progress)
                                .tint(VoxglassTheme.accent)
                            Text("\(TimeFormatting.clock(session.position)) of \(TimeFormatting.clock(session.duration))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(VoxglassTheme.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: session.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(VoxglassTheme.accent)
                    }
                    .padding(14)
                    .glassPanel()
                }
                .buttonStyle(.plain)
            } else if let firstBook = libraryStore.books.first {
                BookRowView(book: firstBook) {
                    Task { await playback.play(firstBook) }
                }
            } else {
                emptyPanel("Import local audio from Library to start listening.")
            }
        }
    }

    @ViewBuilder
    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recently Added")
            if libraryStore.books.isEmpty {
                emptyPanel("Local audiobooks will appear here.")
            } else {
                ForEach(libraryStore.books.prefix(5)) { book in
                    BookRowView(
                        book: book,
                        isCurrent: playback.currentSession?.book.id == book.book.id
                    ) {
                        Task { await playback.play(book) }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(VoxglassTheme.ink)
    }

    private func emptyPanel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(VoxglassTheme.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassPanel()
    }
}

