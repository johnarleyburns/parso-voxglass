import SwiftUI

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    var selectLibrary: () -> Void
    var selectSearch: () -> Void

    @StateObject private var recommendations = HomeRecommendationStore()
    @State private var importingIdentifier: String?
    @AppStorage(AppPreferencesStore.Keys.selectedTasteIDs) private var selectedTasteIDsRaw = ""
    @AppStorage(RecentlyViewedBooksStore.key) private var recentlyViewedRaw = ""

    var body: some View {
        VoxglassScreen(title: "Voxglass") {
            VStack(alignment: .leading, spacing: 22) {
                hero
                recommended
                jumpBackIn
                recentlyViewed
                recentlyAdded
            }
            .padding(.top, 12)
        }
        .alert("Import Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
        .task {
            await libraryStore.refreshRecentlyPlayed()
            await recommendations.load(selectedTasteIDs: selectedTasteIDs)
        }
        .onChange(of: selectedTasteIDsRaw) { _, _ in
            Task {
                await recommendations.load(selectedTasteIDs: selectedTasteIDs)
            }
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
    private var recommended: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(
                title: "Recommended for You",
                actionTitle: recommendations.isRefreshing ? nil : "Search",
                action: recommendations.isRefreshing ? nil : selectSearch
            )

            if recommendations.recommendations.isEmpty {
                EmptyStatePanel(
                    title: "Finding LibriVox Picks",
                    message: "Popular public-domain audiobooks will appear here.",
                    systemImage: "sparkles"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recommendations.recommendations) { result in
                            HorizontalCatalogCard(
                                result: result,
                                isImporting: importingIdentifier == result.identifier
                            ) {
                                Task { await importResult(result) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .overlay(alignment: .topTrailing) {
                    if recommendations.isRefreshing {
                        ProgressView()
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                            .padding(4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var jumpBackIn: some View {
        if playback.currentSession != nil || !libraryStore.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Jump Back In")
                if let session = playback.currentSession {
                    currentSessionCard(session)
                } else if let recent = libraryStore.recentlyPlayed.first {
                    NavigationLink {
                        BookDetailView(book: recent, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        CompactBookRowView(
                            book: recent,
                            sourceTitle: libraryStore.source(for: recent.book)?.title
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func currentSessionCard(_ session: PlaybackSession) -> some View {
        Button {
            showingNowPlaying = true
        } label: {
            HStack(spacing: 14) {
                BookArtworkView(title: session.book.title, size: 70, coverURL: session.book.coverURL)
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
    }

    @ViewBuilder
    private var recentlyViewed: some View {
        let viewedBooks = RecentlyViewedBooksStore.books(from: libraryStore.books, rawValue: recentlyViewedRaw)
        if !viewedBooks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recently Viewed")
                ForEach(viewedBooks.prefix(5)) { book in
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
    private var recentlyAdded: some View {
        if !libraryStore.books.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recently Added", actionTitle: "See All", action: selectLibrary)
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

    private var selectedTasteIDs: Set<String> {
        AppPreferencesStore.decodeTasteIDs(selectedTasteIDsRaw)
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            catalogStore.catalogError != nil || libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        }
    }

    private func importResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
        }
    }
}
