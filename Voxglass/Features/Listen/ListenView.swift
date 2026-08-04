import SwiftUI
import VoxglassCore

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var showingNowPlaying: Bool
    var selectLibrary: () -> Void

    @EnvironmentObject private var recommendations: HomeRecommendationStore
    @State private var importingIdentifier: String?
    @State private var showSettings = false
    @State private var showEQ = false
    @State private var showStats = false
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    var body: some View {
        VoxglassScreen(title: "Voxglass") {
            VStack(alignment: .leading, spacing: 22) {
                hero
                jumpBackIn
                recentlyAdded
                recommended
            }
            .padding(.top, 12)
        }
        .overlay(alignment: .topTrailing) {
            moreMenu
                .padding(.trailing, 16)
                .padding(.top, 6)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(showingNowPlaying: $showingNowPlaying)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showSettings = false }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEQ) {
            NavigationStack {
                EQView()
                    .environment(playback)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showEQ = false }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showStats) {
            NavigationStack {
                ListeningStatsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showStats = false }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .alert("Playback Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
        .task {
            await libraryStore.refreshRecentlyPlayed()
            await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
        }
        .onChange(of: selectedCollectionIDsRaw) { _, _ in
            Task {
                await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
            }
        }
        .onChange(of: selectedLanguagesRaw) { _, _ in
            Task {
                await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
            }
        }
        .onChange(of: showingNowPlaying) { wasShowing, isShowing in
            // Reflect just-finished listening immediately: when Now Playing is
            // dismissed, the taste profile may have shifted, so refresh the shelf
            // (and Jump Back In) without waiting for a tab switch.
            guard wasShowing, !isShowing else { return }
            Task {
                await libraryStore.refreshRecentlyPlayed()
                await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Good listening")
                .scaledFont(size: 31, weight: .heavy)
                .foregroundStyle(Palette.ink)
            Text("Public-domain audiobooks, private by default.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The former "More" tab, reachable from a "…" menu in the top-right
    /// corner of the home view.
    private var moreMenu: some View {
        Menu {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            Button {
                showEQ = true
            } label: {
                Label("Equalizer", systemImage: "waveform.path.ecg")
            }
            Button {
                showStats = true
            } label: {
                Label("Listening Stats", systemImage: "chart.bar.fill")
            }
            NavigationLink {
                AboutView()
            } label: {
                Label("About Voxglass", systemImage: "info.circle.fill")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .scaledFont(size: 21, weight: .semibold)
                .foregroundStyle(Palette.ink2)
                .frame(width: 40, height: 40)
                .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.07))
        }
        .accessibilityIdentifier("home.moreMenu")
        .accessibilityLabel("More")
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
                                BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
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

    private var recentlyAddedBooks: [BookWithChapters] {
        let jumpedBackIDs = Set(libraryStore.recentlyPlayed.map(\.book.id))
        return libraryStore.books.prefix(10).filter { !jumpedBackIDs.contains($0.book.id) }
    }

    @ViewBuilder
    private var recentlyAdded: some View {
        if !recentlyAddedBooks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recently Added", actionTitle: "See All", action: selectLibrary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recentlyAddedBooks) { book in
                            NavigationLink {
                                BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
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
    private var recommended: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Recommended for You")

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
                            Button {
                                Task { await presentResult(result) }
                            } label: {
                                HorizontalCatalogCard(result: result)
                            }
                            .buttonStyle(.plain)
                            .tactileTap()
                            .accessibilityLabel("\(result.title) by \(result.authorLine)")
                            .disabled(importingIdentifier == result.identifier)
                            .overlay {
                                if importingIdentifier == result.identifier {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.black.opacity(0.48))
                                        .overlay {
                                            ProgressView()
                                                .tint(Palette.brass)
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
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

    private var selectedCollectionIDs: Set<String> {
        AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)
    }

    private var selectedLanguages: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
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

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.present(imported)
            showingNowPlaying = true
        }
    }
}

struct ListenBookCard: View {
    let book: BookWithChapters
    let sourceTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookArtworkView(title: book.book.title, size: 132, coverURL: book.book.coverURL, cornerRadius: 14, showBorder: false)
            Text(book.book.title)
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 7)
            Text(book.book.authorLine)
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
            if book.narrationKind == .solo {
                SoloNarrationBadge()
                    .padding(.top, 4)
            } else {
                SoloNarrationBadge()
                    .opacity(0)
                    .padding(.top, 4)
            }
        }
        .frame(width: 132)
    }
}
