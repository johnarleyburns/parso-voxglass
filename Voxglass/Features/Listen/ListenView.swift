import SwiftUI

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    var selectLibrary: () -> Void
    var selectSearch: () -> Void

    var body: some View {
        VoxglassScreen(title: "Home") {
            VStack(alignment: .leading, spacing: 22) {
                hero
                continueListening
                recentlyAdded
                recommended
            }
            .padding(.top, 12)
        }
        .task {
            await libraryStore.refreshRecentlyPlayed()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Good listening")
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
            SectionTitle(title: "Continue Listening")
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
            } else if let recent = libraryStore.recentlyPlayed.first ?? libraryStore.books.first {
                NavigationLink {
                    BookDetailView(book: recent, showingNowPlaying: $showingNowPlaying)
                } label: {
                    CompactBookRowView(
                        book: recent,
                        sourceTitle: libraryStore.source(for: recent.book)?.title
                    )
                }
                .buttonStyle(.plain)
            } else {
                EmptyStatePanel(
                    title: "Nothing Queued",
                    message: "Import audio or search LibriVox to start listening.",
                    systemImage: "headphones"
                )
            }
        }
    }

    @ViewBuilder
    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Recently Added", actionTitle: "See All", action: selectLibrary)
            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "No Audiobooks Yet",
                    message: "Local and archive imports will appear here.",
                    systemImage: "books.vertical"
                )
            } else {
                ForEach(libraryStore.books.prefix(5)) { book in
                    NavigationLink {
                        BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        CompactBookRowView(
                            book: book,
                            sourceTitle: libraryStore.source(for: book.book)?.title
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var recommended: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Recommended for You", actionTitle: "Search", action: selectSearch)

            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "Build Your Shelf",
                    message: "Recommendations use local books in this phase.",
                    systemImage: "sparkles"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(libraryStore.books.prefix(8))) { book in
                            NavigationLink {
                                BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                            } label: {
                                HorizontalBookCard(book: book)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
