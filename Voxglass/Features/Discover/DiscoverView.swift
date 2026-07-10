import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var selectedCategory: LibriVoxBrowseCategory?
    @State private var selectedCollection: IACollection?
    @State private var importingIdentifier: String?
    @AppStorage(AppPreferencesStore.Keys.selectedTasteIDs) private var selectedTasteIDsRaw = ""

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VoxglassScreen(title: "Explore") {
            VStack(alignment: .leading, spacing: 18) {
                collectionShelves
                subjectGrid
                localSourceSections
                catalogResults
            }
            .padding(.top, 12)
        }
        .alert("Explore Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
        .onChange(of: catalogStore.results) { _, results in
            ArtworkService.shared.prefetch(urls: results.map(\.coverURL), limit: 18)
        }
    }

    private var collectionShelves: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Featured Collections")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(IACollectionStore.collections(for: selectedTasteIDs)) { collection in
                        Button {
                            search(collection)
                        } label: {
                            ExploreCollectionCard(
                                collection: collection,
                                isSelected: selectedCollection?.id == collection.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var subjectGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Genres & Subjects")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(LibriVoxBrowseGroup.all) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                            .textCase(.uppercase)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(group.categories) { category in
                                Button {
                                    search(category)
                                } label: {
                                    BrowseTile(
                                        title: category.title,
                                        systemImage: category.systemImage,
                                        isSelected: selectedCategory == category
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var localSourceSections: some View {
        if !libraryStore.sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "On This Device")
                ForEach(libraryStore.sources) { source in
                    let books = libraryStore.books.filter { $0.book.sourceID == source.id }
                    if !books.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(books.prefix(8)) { book in
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
        }
    }

    @ViewBuilder
    private var catalogResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: selectedCategory?.title ?? selectedCollection?.title ?? "Explore Results")

            if catalogStore.isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching LibriVox")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassSurface(cornerRadius: 14)
            } else if catalogStore.results.isEmpty {
                EmptyStatePanel(
                    title: "Choose a Subject",
                    message: "Semantic LibriVox subjects search Internet Archive public-domain audiobooks.",
                    systemImage: "square.grid.2x2"
                )
            } else {
                ForEach(catalogStore.results) { result in
                    InternetArchiveResultRow(
                        result: result,
                        isImporting: importingIdentifier == result.identifier
                    ) {
                        Task { await importResult(result) }
                    }
                }
            }
        }
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

    private func search(_ category: LibriVoxBrowseCategory) {
        selectedCategory = category
        selectedCollection = nil
        Task { await catalogStore.searchAdvanced(category.archiveQuery) }
    }

    private func search(_ collection: IACollection) {
        selectedCollection = collection
        selectedCategory = nil
        Task { await catalogStore.searchAdvanced(collection.archiveQuery) }
    }

    private var selectedTasteIDs: Set<String> {
        AppPreferencesStore.decodeTasteIDs(selectedTasteIDsRaw)
    }
}

private struct BrowseTile: View {
    var title: String
    var systemImage: String
    var isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CollectionArtworkView(
                title: title,
                systemImage: systemImage,
                assetName: "lv-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                remoteImageURL: nil
            )

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.brass : Palette.hairline, lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct ExploreCollectionCard: View {
    var collection: IACollection
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollectionArtworkView(
                title: collection.title,
                systemImage: collection.systemImage,
                assetName: collection.assetName,
                remoteImageURL: collection.remoteImageURL
            )
            .frame(width: 190, height: 132)

            Text(collection.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)

            Text(collection.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)
        }
        .frame(width: 210, alignment: .topLeading)
        .padding(10)
        .glassSurface(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.brass : .clear, lineWidth: 2)
        }
    }
}
