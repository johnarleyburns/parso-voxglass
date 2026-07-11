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

    var body: some View {
        VoxglassScreen(title: "Voxglass") {
            VStack(alignment: .leading, spacing: 22) {
                hero
                jumpBackIn
                recentlyAdded
                favorites
                recommended
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
                .font(.system(size: 31, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(Palette.ink)
            Text("Public-domain audiobooks, private by default.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var jumpBackIn: some View {
        if !libraryStore.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Jump Back In")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(libraryStore.recentlyPlayed) { book in
                            NavigationLink {
                                BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                            } label: {
                                ListenBookCard(
                                    book: book,
                                    sourceTitle: libraryStore.source(for: book.book)?.title
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var recentlyAdded: some View {
        if !libraryStore.books.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recently Added", actionTitle: "See All", action: selectLibrary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(libraryStore.books.prefix(10)) { book in
                            NavigationLink {
                                BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                            } label: {
                                ListenBookCard(
                                    book: book,
                                    sourceTitle: libraryStore.source(for: book.book)?.title
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Favorites")
            if libraryStore.favoriteBooks.isEmpty {
                Text("Favorite a book and it will display here")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
                    .padding(.vertical, 18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(libraryStore.favoriteBooks) { book in
                            NavigationLink {
                                BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                            } label: {
                                ListenBookCard(
                                    book: book,
                                    sourceTitle: libraryStore.source(for: book.book)?.title
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 10)
                }
            }
        }
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
                            .glassSurface(cornerRadius: 18)
                            .padding(4)
                    }
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

struct ListenBookCard: View {
    let book: BookWithChapters
    let sourceTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookCoverView(title: book.book.title, coverURL: book.book.coverURL)
                .frame(width: 132, height: 182)
            Text(book.book.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 7)
            Text(book.book.authorLine)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 132)
    }
}
