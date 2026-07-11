import SwiftUI
import UniformTypeIdentifiers

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var selectedCollection: IACollection?
    @State private var playingIdentifier: String?
    @State private var showingImporter = false
    @State private var archiveURL = ""
    @AppStorage(AppPreferencesStore.Keys.selectedTasteIDs) private var selectedTasteIDsRaw = ""

    var body: some View {
        VoxglassScreen(title: "Explore") {
            VStack(alignment: .leading, spacing: 18) {
                collectionShelves
                addArchiveURLPanel
                importPanel
                catalogResults
            }
            .padding(.top, 12)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: UTType.voxglassImportTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { await handleImportResult(result) }
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

    private var addArchiveURLPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Add from Internet Archive")
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 28)

                TextField("", text: $archiveURL, prompt: Text("archive.org book, list, or collection URL").foregroundStyle(Palette.ink3))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .foregroundStyle(Palette.ink)
                    .onSubmit {
                        Task { await addArchiveURL() }
                    }

                Button {
                    Task { await addArchiveURL() }
                } label: {
                    if catalogStore.isResolvingURL {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.brass)
                .accessibilityLabel("Add archive URL")
                .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 14)
        }
    }

    private var importPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.brass)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Add Local Audiobooks")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("MP3, M4A, M4B, and folders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            Button {
                showingImporter = true
            } label: {
                if libraryStore.isImporting {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.brass)
            .accessibilityLabel("Import local audio")
        }
        .padding(14)
        .glassSurface(cornerRadius: 14)
    }

    @ViewBuilder
    private var catalogResults: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    private func addArchiveURL() async {
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            archiveURL = ""
            await playback.play(imported)
            showingNowPlaying = true
        }
        await libraryStore.refresh()
    }

    private func handleImportResult(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            let imported = await libraryStore.importLocalAudio(from: urls)
            if let first = imported.first {
                await playback.play(first)
                showingNowPlaying = true
            }
        case .failure(let error):
            libraryStore.importError = error.localizedDescription
        }
    }

    private var selectedTasteIDs: Set<String> {
        AppPreferencesStore.decodeTasteIDs(selectedTasteIDsRaw)
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
