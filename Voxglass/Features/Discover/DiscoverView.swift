import SwiftUI
import VoxglassCore

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var showingNowPlaying: Bool
    @State private var selectedCollection: IACollection?
    @State private var rememberedCollection: IACollection?
    @State private var collectionSort: CatalogSort = .popularity
    @StateObject private var coverStore = CollectionCoverStore(artwork: ArtworkService.shared)
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"
    @State private var showDownloadAllAlert = false
    // Advanced catalog filters belong to this discovery surface only. Do not
    // persist them as app-wide preferences or a choice here can silently
    // narrow another catalog surface later.
    @State private var soloOnly = false
    @State private var searchScope: DiscoverSearchScope = .all
    @State private var selectedCatalogResult: InternetArchiveSearchResult?
    @State private var selectedCatalogResultID: String?
    @State private var showingHistory = false
    @State private var showSearch = false
    @State private var discoverScope: DiscoverBrowseScope = .collection
    @State private var showingCollectionInfo: IACollection?
    @State private var loadingCollectionID: String?
    @State private var lastCollectionLoadKey: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VoxglassScreen(
            title: "Discover",
            scrollToTopTrigger: AnyHashable(selectedCollection?.id ?? "discover.featured"),
            headerTrailingContent: AnyView(discoverHeaderActions),
            content: { discoverContent }
        )
        .navigationDestination(item: $selectedCatalogResultID) { _ in
            selectedCatalogDestination
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(showingNowPlaying: $showingNowPlaying)
                .environmentObject(libraryStore)
        }
        .sheet(item: $showingCollectionInfo, content: collectionInfoSheet)
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("Discover Failed"),
                message: Text(verbatim: discoverErrorMessage),
                dismissButton: .cancel(Text("OK"), action: clearDiscoverErrors)
            )
        }
        .toolbar { discoverKeyboardToolbar }
        .task {
            catalogStore.selectedLanguages = selectedLanguages
            let collections = IACollectionStore.collections(for: selectedCollectionIDs, languages: selectedLanguages)
            async let covers: Void = coverStore.resolveCovers(for: collections, languages: selectedLanguages)
            async let counts: Void = coverStore.resolveCounts(for: collections, languages: selectedLanguages)
            _ = await (covers, counts)
        }
        .onChange(of: selectedLanguagesRaw) { _, _ in
            catalogStore.selectedLanguages = selectedLanguages
            Task {
                let collections = IACollectionStore.collections(for: selectedCollectionIDs, languages: selectedLanguages)
                async let covers: Void = coverStore.resolveCovers(for: collections, languages: selectedLanguages, force: true)
                async let counts: Void = coverStore.resolveCounts(for: collections, languages: selectedLanguages, force: true)
                _ = await (covers, counts)
            }
        }
        .onChange(of: catalogStore.results) { _, results in
            ArtworkService.shared.prefetch(urls: results.map(\.coverURL), limit: 18)
        }
        .onChange(of: collectionSort) { _, _ in
            guard selectedCollection != nil else { return }
            guard let collection = selectedCollection else { return }
            startCollectionLoad(collection, sort: collectionSort)
        }
        .onChange(of: searchScope) { _, _ in
            guard !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await runSearch() }
        }
        .onChange(of: discoverScope) { _, scope in
            handleDiscoverScopeChange(scope)
        }
    }

    private var discoverContent: some View {
            VStack(alignment: .leading, spacing: 18) {
                scopeBar
                if let selectedCollection {
                    selectedCollectionPill(selectedCollection)
                }
                if showSearch {
                    searchPanel
                }
                if shouldShowFeaturedCollections {
                    collectionShelves
                }
                catalogResults
            }
            .padding(.top, 12)
    }

    @ViewBuilder
    private var selectedCatalogDestination: some View {
        if let selectedCatalogResult {
            CatalogBookDestinationView(result: selectedCatalogResult, showingNowPlaying: $showingNowPlaying)
        } else {
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var discoverKeyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button {
                searchFocused = false
            } label: {
                Text("Done")
            }
            .accessibilityIdentifier("discover.dismissKeyboard")
        }
    }

    private func handleDiscoverScopeChange(_ scope: DiscoverBrowseScope) {
        let hasQuery = !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if scope == .all {
            if let selectedCollection {
                rememberedCollection = selectedCollection
                self.selectedCollection = nil
            }
            if hasQuery {
                Task { await runSearch() }
            } else {
                catalogStore.resetResultsForNavigation()
            }
            return
        }

        if let rememberedCollection, selectedCollection == nil {
            let sort = CatalogSort.defaultSort(for: rememberedCollection)
            selectedCollection = rememberedCollection
            collectionSort = sort
            catalogStore.query = ""
            searchScope = .all
            catalogStore.resetResultsForNavigation()
            startCollectionLoad(rememberedCollection, sort: sort)
            return
        }

        if hasQuery {
            catalogStore.query = ""
            searchScope = .all
        }
        if let selectedCollection {
            startCollectionLoad(selectedCollection, sort: collectionSort)
        } else {
            catalogStore.resetResultsForNavigation()
        }
    }

    private var discoverHeaderActions: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch.toggle()
                    if showSearch {
                        if selectedCollection == nil {
                            discoverScope = .all
                            catalogStore.resetResultsForNavigation()
                        }
                        searchFocused = true
                    } else {
                        searchFocused = false
                        clearSearchAndRestoreBrowseState()
                    }
                }
            } label: {
                Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .voxFont(.body, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(showSearch ? "Close search" : "Search Discover") // l10n-exempt: state-dependent accessibility or status copy
            .accessibilityIdentifier("discover.searchButton")

            Menu {
                Picker("Search in", selection: $searchScope) {
                    ForEach(DiscoverSearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Divider()
                Toggle("Single narrator", isOn: $soloOnly)
                if selectedCollection != nil {
                    Picker("Sort", selection: $collectionSort) {
                        ForEach(CatalogSort.availableSorts(for: selectedCollection ?? IACollectionStore.popular)) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    if selectedCollection?.isCurated == true, !catalogStore.activeCuratedManifest.isEmpty {
                        Text("Download all is available in collection details")
                            .voxFont(.caption)
                            .foregroundStyle(Palette.ink3)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .voxFont(.body, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Filter and sort")
            .accessibilityIdentifier("discover.filterButton")

            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .voxFont(.body, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Listening History")
            .accessibilityIdentifier("discover.historyButton")
        }
    }

    private var scopeBar: some View {
        BookScopeBar(title: "Discover scope", selection: $discoverScope, options: [
            (.all, "All"), (.collection, "Collection")
        ])
        .accessibilityIdentifier("discover.scopePicker")
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.ink3)

                TextField("Search books, authors, or narrators", text: $catalogStore.query)
                    .foregroundStyle(Palette.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityLabel("Search catalog for books, authors, or narrators")
                    .accessibilityIdentifier("discover.catalogSearch")
                    .focused($searchFocused)
                    .onSubmit { Task { await runSearch() } }

                if !catalogStore.query.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearch = false
                            searchFocused = false
                            clearSearchAndRestoreBrowseState()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.ink3)
                    }
                    .accessibilityLabel("Clear catalog search")
                }

                if catalogStore.isSearching {
                    ProgressView()
                        .frame(width: 20, height: 20)
                }
            }
            .voxFont(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .raisedSurface()

            Picker("Search in", selection: $searchScope) {
                ForEach(DiscoverSearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .tint(Palette.brass)
            .accessibilityIdentifier("discover.searchScope")
        }
    }

    private func selectedCollectionPill(_ collection: IACollection) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .voxFont(.caption, weight: .semibold)
                Text(collection.title)
                    .voxFont(.caption, weight: .semibold)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedCollection = nil
                        discoverScope = catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .collection : .all
                        if catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            catalogStore.resetResultsForNavigation()
                        } else {
                            Task { await runSearch() }
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .voxFont(.caption2, weight: .bold)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Clear selected collection")
                .accessibilityIdentifier("discover.selectedCollection.clear")
            }
            .foregroundStyle(Palette.brass)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .raisedSurface()
            .accessibilityIdentifier("discover.selectedCollection")

            Button {
                showingCollectionInfo = collection
            } label: {
                Label("About", systemImage: "info.circle")
                    .labelStyle(.titleAndIcon)
                    .voxFont(.footnote, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .raisedSurface()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("discover.selectedCollectionAbout")

            Spacer(minLength: 0)
        }
    }

    private var collectionShelves: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Featured Collections")
            VStack(spacing: 10) {
                ForEach(IACollectionStore.collections(for: selectedCollectionIDs, languages: selectedLanguages)) { collection in
                    ExploreCollectionCard(
                        collection: collection,
                        previews: coverStore.previews(for: collection),
                        resolvedCoverURL: coverStore.coverURL(for: collection),
                        approximateCount: coverStore.count(for: collection),
                        isSelected: false,
                        isLoading: loadingCollectionID == collection.id,
                        onSelect: { search(collection) }
                    )
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .animation(.easeInOut(duration: 0.25), value: shouldShowFeaturedCollections)
    }

    private var shouldShowFeaturedCollections: Bool {
        discoverScope == .collection && selectedCollection == nil
    }

    @ViewBuilder
    private var catalogResults: some View {
        if hasActiveCatalogResultsSurface {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: LocalizedStringKey(resultsTitle))
                if selectedCollection != nil {
                    if selectedCollection?.isCurated == true {
                        curatedStatusBanner
                        downloadAllButton
                    }
                }

                if catalogStore.results.isEmpty {
                    if catalogStore.isSearching {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching LibriVox")
                                .voxFont(.subheadline)
                                .foregroundStyle(Palette.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .raisedSurface()
                    } else {
                        EmptyStatePanel(
                            title: catalogStore.query.isEmpty ? "No Books Yet" : "No Results Yet",
                            message: catalogStore.query.isEmpty
                                ? "Try another collection or search above."
                                : "Try a different title, author, or narrator.",
                            systemImage: "square.stack"
                        )
                    }
                } else {
                    let results = soloOnly
                        ? catalogStore.results.filter { $0.narrationKind == .solo }
                        : catalogStore.results
                    if results.isEmpty && soloOnly {
                        EmptyStatePanel(
                            title: "No Single-narrator Results",
                            message: "Try turning off the Single narrator filter to see more audiobooks.",
                            systemImage: "mic"
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                Button {
                                    Task { await presentResult(result) }
                                } label: {
                                    InternetArchiveResultRow(
                                        result: result,
                                        style: .grouped,
                                        isLoading: false
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("discover.result.\(result.identifier)")
                                .accessibilityHint("Opens a paused preview with Play and Add to My Books actions")
                                .disabled(catalogStore.isSearching)

                                if index < results.count - 1 {
                                    VoxglassListDivider()
                                }
                            }
                        }
                        .padding(.top, 4)
                        .raisedSurface()
                        .opacity(catalogStore.isSearching ? 0.5 : 1.0)
                    }

                    if catalogStore.hasMore {
                        loadMoreButton
                    }
                }
            }
        }
    }

    private var hasActiveCatalogResultsSurface: Bool {
        !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCollection != nil
            || catalogStore.isSearching
            || !catalogStore.results.isEmpty
            || discoverScope == .all
    }

    private var resultsTitle: String {
        if !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Search Results")
        }
        if let selectedCollection { return selectedCollection.title }
        return String(localized: "Search Results")
    }

    private var curatedStatusBanner: some View {
        Text(curatedStatusMessage)
            .voxFont(.caption2, weight: .medium)
            .foregroundStyle(Palette.brass)
            .padding(.bottom, 2)
            .accessibilityLabel(curatedStatusMessage)
    }

    private var curatedStatusMessage: String {
        switch collectionSort {
        case .curation:
            String(localized: "Hand-picked list · shown in curation order")
        case .popularity:
            String(localized: "Sorted by popularity")
        case .title:
            String(localized: "Sorted by title")
        case .author:
            String(localized: "Sorted by author")
        case .recordedDate:
            String(localized: "Sorted by date")
        }
    }

    private var downloadAllButton: some View {
        VStack(spacing: 8) {
            if let progress = catalogStore.batchProgress {
                VStack(spacing: 4) {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                        HStack {
                            Text("Downloading \(progress.completed) of \(progress.total)")
                                .voxFont(.caption, weight: .medium)
                                .foregroundStyle(Palette.ink2)
                            Spacer()
                            Button("Cancel") {
                                catalogStore.cancelBatchDownload()
                            }
                            .voxFont(.caption, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                        }
                    }
                    .tint(Palette.brass)
                }
                .padding(.vertical, 4)
            }

            if !catalogStore.isBatchDownloading {
                let manifestCount = catalogStore.activeCuratedManifest.count
                if manifestCount > 0 {
                    Button {
                        showDownloadAllAlert = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .voxFont(.subheadline)
                            Text("Download All (\(manifestCount) items)")
                                .voxFont(.footnote, weight: .semibold)
                        }
                        .foregroundStyle(Palette.brass)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .raisedSurface()
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Download All",
                        isPresented: $showDownloadAllAlert,
                        titleVisibility: .visible
                    ) {
                        Button("Download \(manifestCount) items", role: .destructive) {
                            Task { await catalogStore.downloadAllCurated(into: libraryStore) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("""
                            This will download all \(manifestCount) audiobooks in this collection. \
                            Estimated total: ~\(CatalogStore.formattedBatchSize(entryCount: manifestCount)). \
                            Downloading over cellular may incur data charges. \
                            Are you sure you want to continue?
                            """)
                    }
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
                        .voxFont(.caption2, weight: .bold)
                }
            }
            .voxFont(.subheadline, weight: .semibold)
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .raisedSurface()
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

    private func search(_ collection: IACollection) {
        let defaultSort = CatalogSort.defaultSort(for: collection)
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedCollection = collection
            rememberedCollection = collection
            showSearch = false
            searchFocused = false
            catalogStore.query = ""
            collectionSort = defaultSort
        }
        startCollectionLoad(collection, sort: defaultSort)
    }

    private func startCollectionLoad(_ collection: IACollection, sort: CatalogSort) {
        // The selection is immediate, while the request runs independently of
        // SwiftUI's state-commit timing. This prevents a tap from launching a
        // request with the previous (or nil) collection and gives the card a
        // visible loading state on the first tap.
        let loadKey = "\(collection.id)|\(String(describing: sort))"
        if loadingCollectionID == collection.id, lastCollectionLoadKey == loadKey {
            return
        }
        lastCollectionLoadKey = loadKey
        loadingCollectionID = collection.id
        Task {
            await loadSelectedCollection(collection: collection, sort: sort)
            guard selectedCollection?.id == collection.id else { return }
            loadingCollectionID = nil
        }
    }

    private func loadSelectedCollection(collection: IACollection? = nil, sort: CatalogSort? = nil) async {
        guard let collection = collection ?? selectedCollection else { return }
        await catalogStore.searchAdvanced(
            collection.archiveQuery,
            sort: sort ?? collectionSort,
            collectionID: collection.id
        )
    }

    private func runSearch() async {
        let term = catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty || selectedCollection != nil else {
            catalogStore.resetResultsForNavigation()
            return
        }

        if let selectedCollection {
            let collectionQuery = term.isEmpty
                ? selectedCollection.archiveQuery
                : "(\(selectedCollection.archiveQuery)) AND (\(scopedQuery(term, includeCatalogScope: false)))"
            await catalogStore.searchAdvanced(collectionQuery, sort: collectionSort, collectionID: selectedCollection.id)
            return
        }

        discoverScope = .all
        switch searchScope {
        case .all:
            await catalogStore.searchLibriVox(term)
        case .title, .author, .narrator:
            await catalogStore.searchAdvanced(scopedQuery(term), sort: .popularity)
        }
    }

    private func scopedQuery(_ text: String, includeCatalogScope: Bool = true) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "")
        let scopeClause = includeCatalogScope ? " AND \(LibriVoxCatalogScope.query)" : ""

        switch searchScope {
        case .all:
            return text
        case .title:
            return "title:\"\(escaped)\"\(scopeClause)"
        case .author:
            return "creator:\"\(escaped)\"\(scopeClause)"
        case .narrator:
            return "(creator:\"\(escaped)\" OR description:\"\(escaped)\")\(scopeClause)"
        }
    }

    private func clearSearchAndRestoreBrowseState() {
        catalogStore.query = ""
        searchScope = .all
        if selectedCollection == nil {
            discoverScope = .collection
            catalogStore.resetResultsForNavigation()
        } else {
            discoverScope = .collection
            Task { await loadSelectedCollection() }
        }
    }

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        // Push immediately; CatalogBookDestinationView performs the metadata
        // import after navigation so the tap has instant visual feedback.
        selectedCatalogResult = result
        selectedCatalogResultID = result.identifier
    }

    private var selectedCollectionIDs: Set<String> {
        AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)
    }

    private var selectedLanguages: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
    }

    private var discoverErrorMessage: String {
        catalogStore.catalogError ?? libraryStore.importError ?? ""
    }

    private func clearDiscoverErrors() {
        catalogStore.catalogError = nil
        libraryStore.importError = nil
    }

    private func collectionInfoSheet(_ collection: IACollection) -> some View {
        CollectionInfoSheet(
            collection: collection,
            resolvedCoverURL: coverStore.coverURL(for: collection),
            approximateCount: coverStore.count(for: collection)
        )
    }
}

private enum DiscoverSearchScope: CaseIterable, Identifiable, Hashable {
    case all
    case title
    case author
    case narrator

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .title: return String(localized: "Title")
        case .author: return String(localized: "Author")
        case .narrator: return String(localized: "Narrator")
        }
    }
}

private enum DiscoverBrowseScope: String, CaseIterable, Identifiable {
    case all
    case collection

    var id: String { rawValue }
}

private struct ExploreCollectionCard: View {
    var collection: IACollection
    var previews: [CollectionBookPreview]
    var resolvedCoverURL: URL?
    var approximateCount: Int?
    var isSelected: Bool
    var isLoading: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    CollectionFan(books: fanBooks)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(collection.title).voxType(.collectionTitle).foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                }
                Text(collection.description).voxType(.meta).foregroundStyle(Palette.ink3).lineLimit(2)
                if let caption = approximateCountCaption { Text(caption).voxType(.eyebrow).foregroundStyle(Palette.ink2) }
            }
            .padding(14)
            // The visual surface is the control. Keep the complete card in
            // the button's hit shape so taps on its title, description,
            // count, and empty artwork space all open the collection.
            // Give the Button label the full visual card bounds. A frame on
            // the Button itself changes layout, but does not reliably expand
            // the label's hit target into otherwise empty card space.
            .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("discover.collection.\(collection.id)")
        .frame(maxWidth: .infinity)
        .frame(height: 196)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .raisedSurface()
        .overlay(alignment: .topTrailing) {
            if collection.isCurated { curatedBadge }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.brass : .clear, lineWidth: 2)
        }
        .overlay {
            if isLoading {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.bg.opacity(0.72))
                ProgressView()
                    .tint(Palette.brass)
                    .scaleEffect(1.15)
                    .accessibilityLabel("Loading collection")
            }
        }
    }

    /// The resolver returns the most popular books first. CollectionFan draws
    /// its plates back-to-front, so reverse the three previews before drawing
    /// them to put the most popular title on the front/top plate.
    private var fanBooks: [(title: String, author: String?)] {
        let books = Array(previews.prefix(3).reversed())
        return (0..<3).map { index in
            guard books.indices.contains(index) else { return (collection.title, nil) }
            let book = books[index]
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = author.lowercased().replacingOccurrences(of: "  ", with: " ")
            let isPlaceholder = normalized.isEmpty
                || normalized == "unknown"
                || normalized == "unknown author"
                || normalized == "uknown"
                || normalized == "uknown author"
            return (book.title, isPlaceholder ? nil : author)
        }
    }

    private var curatedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "rosette")
                .voxFont(.caption2, weight: .bold)
            Text("CURATED")
                .voxFont(.caption2, weight: .bold)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Palette.brass)
        .cornerRadius(4)
        .padding(6)
        .accessibilityElement()
        .accessibilityLabel("Curated collection")
        .accessibilityIdentifier("collection.curatedBadge")
    }

    private var approximateCountCaption: String? {
        guard let count = approximateCount, count > 0 else { return nil }
        if collection.isCurated {
            let formatted = Self.formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            return String(localized: "\(formatted) books")
        }
        let rounded = Self.roundedToTwoSignificantFigures(count)
        let formatted = Self.formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return String(localized: "\(formatted)+ books")
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    private static func roundedToTwoSignificantFigures(_ value: Int) -> Int {
        guard value >= 100 else { return value }
        let digits = Int(floor(log10(Double(value)))) + 1
        let factor = Int(pow(10.0, Double(digits - 2)))
        return Int((Double(value) / Double(factor)).rounded()) * factor
    }
}

private struct CollectionInfoSheet: View {
    let collection: IACollection
    let resolvedCoverURL: URL?
    let approximateCount: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CollectionArtworkView(
                        title: collection.title,
                        systemImage: collection.systemImage,
                        assetName: collection.assetName,
                        remoteImageURL: resolvedCoverURL
                    )
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text(collection.title)
                        .voxFont(.title2, weight: .heavy)
                        .foregroundStyle(Palette.ink)
                    if let approximateCount, approximateCount > 0 {
                        Text("Approximately \(approximateCount.formatted()) books")
                            .voxFont(.footnote, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                    }
                    if !collection.summaryLine.isEmpty {
                        Text(collection.summaryLine)
                            .voxFont(.subheadline, weight: .semibold)
                            .foregroundStyle(Palette.ink2)
                    }
                    Text(collection.description)
                        .voxFont(.subheadline)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationTitle("Collection info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
