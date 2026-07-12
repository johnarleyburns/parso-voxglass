import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var selectedCollection: IACollection?
    @State private var playingIdentifier: String?
    @StateObject private var coverStore = CollectionCoverStore()
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    var body: some View {
        VoxglassScreen(title: "Explore") {
            VStack(alignment: .leading, spacing: 18) {
                collectionShelves
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
        .task {
            catalogStore.selectedLanguages = selectedLanguages
            await coverStore.resolveCovers(for: IACollectionStore.collections(for: selectedCollectionIDs), languages: selectedLanguages)
        }
        .onChange(of: selectedLanguagesRaw) { _, _ in
            catalogStore.selectedLanguages = selectedLanguages
            Task {
                await coverStore.resolveCovers(for: IACollectionStore.collections(for: selectedCollectionIDs), languages: selectedLanguages, force: true)
            }
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
                    ForEach(IACollectionStore.collections(for: selectedCollectionIDs)) { collection in
                        Button {
                            search(collection)
                        } label: {
                            ExploreCollectionCard(
                                collection: collection,
                                resolvedCoverURL: coverStore.coverURL(for: collection),
                                isSelected: selectedCollection?.id == collection.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var catalogResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: selectedCollection?.title ?? "Explore Results")

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
                    title: "Pick a Collection",
                    message: "Choose a Featured Collection above to explore curated LibriVox audiobooks. Tap any result to start listening.",
                    systemImage: "square.stack"
                )
            } else {
                ForEach(catalogStore.results) { result in
                    Button {
                        Task { await playResult(result) }
                    } label: {
                        InternetArchiveResultRow(
                            result: result,
                            isPlaying: playingIdentifier == result.identifier
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(playingIdentifier == result.identifier)
                }

                if catalogStore.hasMore {
                    loadMoreButton
                }
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await catalogStore.loadMore() }
        } label: {
            HStack(spacing: 10) {
                if catalogStore.isLoadingMore {
                    ProgressView()
                    Text("Loading")
                } else {
                    Text("See More")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .disabled(catalogStore.isLoadingMore)
        .onAppear {
            Task { await catalogStore.loadMore() }
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

    private func playResult(_ result: InternetArchiveSearchResult) async {
        playingIdentifier = result.identifier
        defer { playingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
        }
    }

    private func search(_ collection: IACollection) {
        selectedCollection = collection
        Task { await catalogStore.searchAdvanced(collection.archiveQuery) }
    }

    private var selectedCollectionIDs: Set<String> {
        AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)
    }

    private var selectedLanguages: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
    }
}

private struct ExploreCollectionCard: View {
    var collection: IACollection
    var resolvedCoverURL: URL?
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollectionArtworkView(
                title: collection.title,
                systemImage: collection.systemImage,
                assetName: collection.assetName,
                remoteImageURL: resolvedCoverURL ?? collection.remoteImageURL
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
