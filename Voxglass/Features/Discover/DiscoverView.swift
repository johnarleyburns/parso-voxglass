import SwiftUI
import VoxglassCore

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(CatalogStore.self) private var catalogStore
    @Environment(GutenbergIndexStore.self) private var gutenbergIndex
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
    @State private var sourceFilter: FindSourceFilter = .librivox
    @State private var gutenbergResults: [GutenbergBook] = []
    @State private var isSearchingGutenberg = false
    @State private var gutenbergSearchID = UUID()
    @State private var gutenbergTask: Task<Void, Never>?
    @State private var librivoxTask: Task<Void, Never>?
    @State private var collectionLoadTask: Task<Void, Never>?
    @State private var selectedGutenbergBook: GutenbergBook?
    @State private var searchLifecycle = FindSearchLifecycle()
    @State private var preflightTask: Task<Void, Never>?
    @State private var selectedCatalogResult: CatalogResultRoute?
    @State private var showingHistory = false
    @State private var showingCollectionInfo: IACollection?
    @State private var loadingCollectionID: String?
    @State private var lastCollectionLoadKey: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VoxglassScreen(
            title: "Find",
            scrollToTopTrigger: AnyHashable(selectedCollection?.id ?? "discover.featured"),
            headerTrailingContent: AnyView(discoverHeaderActions),
            content: { discoverContent }
        )
        .sheet(isPresented: $showingHistory) {
            HistoryView(showingNowPlaying: $showingNowPlaying)
                .environmentObject(libraryStore)
        }
        .sheet(item: $showingCollectionInfo, content: collectionInfoSheet)
        .sheet(item: $selectedGutenbergBook) { book in
            GutenbergBookPreview(book: book, showingNowPlaying: $showingNowPlaying)
                .environmentObject(libraryStore)
                .environment(playback)
        }
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("Find Failed"),
                message: Text(verbatim: discoverErrorMessage),
                dismissButton: .cancel(Text("OK"), action: clearDiscoverErrors)
            )
        }
        .toolbar { discoverKeyboardToolbar }
        .onDisappear {
            preflightTask?.cancel()
            cancelSearchRequests()
        }
        .task {
            catalogStore.selectedLanguages = selectedLanguages
            let indexStore = gutenbergIndex
            Task { @MainActor in
                await indexStore.load()
                await indexStore.refreshIfNeeded()
            }
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
            startOwnershipPreflight(for: results)
        }
        .onChange(of: gutenbergResults) { _, results in
            ArtworkService.shared.prefetch(urls: results.compactMap(\.coverURL), limit: 18)
        }
        .onChange(of: collectionSort) { _, _ in
            guard selectedCollection != nil else { return }
            guard let collection = selectedCollection else { return }
            startCollectionLoad(collection, sort: collectionSort)
        }
        .onChange(of: searchScope) { _, _ in
            guard searchLifecycle.isCurrent(draft: catalogStore.query) else { return }
            Task { await runSearch() }
        }
        .onChange(of: sourceFilter) { _, _ in
            handleSourceChange()
        }
        .onChange(of: catalogStore.query) { _, query in
            preflightTask?.cancel()
            preflightTask = nil
            if FindSearchLifecycle.normalized(query).isEmpty { searchLifecycle.reset() }
        }
    }

    private var discoverContent: some View {
            VStack(alignment: .leading, spacing: 18) {
                searchPanel
                if let selectedCollection {
                    selectedCollectionPill(selectedCollection)
                }
                if shouldShowFeaturedCollections {
                    collectionShelves
                }
                catalogResults
            }
            .padding(.top, 12)
            // Must live inside VoxglassScreen's content: it wraps content in its
            // own NavigationStack, so a destination attached outside is never
            // registered and taps would appear inert (see LibraryView).
            .navigationDestination(item: $selectedCatalogResult) { route in
                CatalogBookDestinationView(result: route.result, showingNowPlaying: $showingNowPlaying)
                    .id(route.id)
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

    private func handleSourceChange() {
        let hasQuery = searchLifecycle.isCurrent(draft: catalogStore.query)
        cancelSearchRequests()
        preflightTask?.cancel()
        preflightTask = nil
        catalogStore.resetResultsForNavigation()

        if sourceFilter == .collections {
            catalogStore.query = ""
            searchLifecycle.reset()
            if let rememberedCollection {
                selectedCollection = rememberedCollection
                collectionSort = CatalogSort.defaultSort(for: rememberedCollection)
                startCollectionLoad(rememberedCollection, sort: collectionSort)
            }
        } else {
            if let selectedCollection { rememberedCollection = selectedCollection }
            selectedCollection = nil
            if hasQuery { Task { await runSearch() } }
        }
    }

    private var discoverHeaderActions: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Search in", selection: $searchScope) {
                    Text("All").tag(DiscoverSearchScope.all)
                    Text("Title").tag(DiscoverSearchScope.title)
                    Text("Author").tag(DiscoverSearchScope.author)
                    Text("Narrator").tag(DiscoverSearchScope.narrator)
                }
                .pickerStyle(.inline)
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
                            .voxFont(LibraryScreenTypography.card)
                            .foregroundStyle(Palette.ink3)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Filter and sort")
            .accessibilityIdentifier("discover.filterButton")

            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Listening History")
            .accessibilityIdentifier("discover.historyButton")
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.ink3)

                TextField("Search books, authors, or narrators", text: Binding(get: { catalogStore.query }, set: { catalogStore.query = $0 }))
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
                        searchFocused = false
                        clearSearchAndRestoreBrowseState()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.ink3)
                    }
                    .accessibilityLabel("Clear catalog search")
                }

                if (sourceFilter == .gutenberg ? isSearchingGutenberg : catalogStore.isSearching) {
                    ProgressView()
                        .frame(width: 20, height: 20)
                }
            }
            .voxFont(LibraryScreenTypography.controls)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .raisedSurface()

            BookScopeBar(title: "Find source", selection: $sourceFilter, options: [
                (.librivox, "LibriVox"), (.collections, "LibriVox Collections"), (.gutenberg, "Gutenberg Read by AI")
            ])
            .accessibilityIdentifier("discover.sourceFilter")
        }
    }

    private func selectedCollectionPill(_ collection: IACollection) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .voxFont(LibraryScreenTypography.card, weight: .semibold)
                Text(collection.title)
                    .voxFont(LibraryScreenTypography.card, weight: .semibold)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        cancelSearchRequests()
                        selectedCollection = nil
                        rememberedCollection = nil
                        if !searchLifecycle.isCurrent(draft: catalogStore.query) {
                            catalogStore.resetResultsForNavigation()
                        } else {
                            Task { await runSearch() }
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .voxFont(LibraryScreenTypography.card, weight: .bold)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Clear selected collection")
                .accessibilityIdentifier("discover.selectedCollection.clear")
            }
            .foregroundStyle(Palette.brass)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .raisedSurface()
            .accessibilityIdentifier("discover.selectedCollection")

            Button {
                showingCollectionInfo = collection
            } label: {
                Label("About", systemImage: "info.circle")
                    .labelStyle(.titleAndIcon)
                    .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .raisedSurface()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("discover.selectedCollectionAbout")

            Spacer(minLength: 0)
        }
    }

    private var collectionShelves: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Featured Collections", usesThreeSizeTypography: true)
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
        sourceFilter == .collections && selectedCollection == nil
    }

    @ViewBuilder
    private var catalogResults: some View {
        if isInitialFindState {
            EmptyStatePanel(
                title: "Find a book",
                message: "Search results will display here after you press Find.",
                systemImage: "magnifyingglass",
                usesThreeSizeTypography: true
            )
        } else if hasActiveCatalogResultsSurface {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: LocalizedStringKey(resultsTitle), usesThreeSizeTypography: true)
                if selectedCollection != nil {
                    if selectedCollection?.isCurated == true {
                        curatedStatusBanner
                        downloadAllButton
                    }
                }

                if sourceFilter == .gutenberg {
                    if !gutenbergResults.isEmpty {
                        gutenbergResultSection
                    } else if isSearchingGutenberg {
                        gutenbergLoadingSection
                    } else if searchLifecycle.isCurrent(draft: catalogStore.query) {
                        EmptyStatePanel(title: "No Results Yet", message: "Try a different title, author, or narrator.", systemImage: "magnifyingglass", usesThreeSizeTypography: true)
                    }
                } else if catalogStore.results.isEmpty {
                    if catalogStore.isSearching {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(searchProgressLabel)
                                .voxFont(LibraryScreenTypography.controls)
                                .foregroundStyle(Palette.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .raisedSurface()
                    } else {
                        switch searchLifecycle.emptyState(draft: catalogStore.query) {
                        case .instructional:
                            EmptyStatePanel(
                                title: "Find a book",
                                message: "Search results will display here after you press Find.",
                                systemImage: "magnifyingglass",
                                usesThreeSizeTypography: true
                            )
                        case .noBooks:
                            EmptyStatePanel(
                                title: "No Books Yet",
                                message: "Try another collection or search above.",
                                systemImage: "square.stack",
                                usesThreeSizeTypography: true
                            )
                        case .noResults:
                            EmptyStatePanel(
                                title: "No Results Yet",
                                message: "Try a different title, author, or narrator.",
                                systemImage: "square.stack",
                                usesThreeSizeTypography: true
                            )
                        }
                    }
                } else {
                    let results = soloOnly
                        ? catalogStore.results.filter { $0.narrationKind == .solo }
                        : catalogStore.results
                    if results.isEmpty && soloOnly {
                        EmptyStatePanel(
                            title: "No Single-narrator Results",
                            message: "Try turning off the Single narrator filter to see more audiobooks.",
                            systemImage: "mic",
                            usesThreeSizeTypography: true
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                Button {
                                    Task { await presentResult(result) }
                                } label: {
                                    InternetArchiveResultRow(
                                        result: result,
                                        style: .grouped,
                                        isLoading: false,
                                        isInMyBooks: libraryStore.cachedOwnedBook(for: result) != nil,
                                        usesThreeSizeTypography: true
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("discover.result.\(result.identifier)")
                                .accessibilityHint(libraryStore.cachedOwnedBook(for: result) != nil ? String(localized: "Opens the existing item in My Books") : String(localized: "Opens a paused preview with Play and Add to My Books actions"))
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
        searchLifecycle.showsResultsSurface(
            draft: catalogStore.query,
            hasSelectedCollection: selectedCollection != nil,
            isSearching: sourceFilter == .gutenberg ? isSearchingGutenberg : catalogStore.isSearching,
            hasResults: sourceFilter == .gutenberg ? !gutenbergResults.isEmpty : !catalogStore.results.isEmpty
        )
    }

    private var isInitialFindState: Bool {
        !hasActiveCatalogResultsSurface
    }

    private var resultsTitle: String {
        let draft = FindSearchLifecycle.normalized(catalogStore.query)
        if !draft.isEmpty {
            return searchLifecycle.isCurrent(draft: draft)
                ? String(localized: "Search Results")
                : String(localized: "Previous Results")
        }
        if let selectedCollection { return selectedCollection.title }
        return String(localized: "Search Results")
    }

    private var curatedStatusBanner: some View {
        Text(curatedStatusMessage)
            .voxFont(LibraryScreenTypography.card, weight: .medium)
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
                                .voxFont(LibraryScreenTypography.card, weight: .medium)
                                .foregroundStyle(Palette.ink2)
                            Spacer()
                            Button("Cancel") {
                                catalogStore.cancelBatchDownload()
                            }
                            .voxFont(LibraryScreenTypography.card, weight: .semibold)
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
                                .voxFont(LibraryScreenTypography.controls)
                            Text("Download All (\(manifestCount) items)")
                                .voxFont(LibraryScreenTypography.controls, weight: .semibold)
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
                        .voxFont(LibraryScreenTypography.card, weight: .bold)
                }
            }
            .voxFont(LibraryScreenTypography.controls, weight: .semibold)
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
        collectionLoadTask?.cancel()
        collectionLoadTask = Task {
            guard !Task.isCancelled else { return }
            await loadSelectedCollection(collection: collection, sort: sort)
            guard !Task.isCancelled, selectedCollection?.id == collection.id else { return }
            loadingCollectionID = nil
        }
    }

    private func loadSelectedCollection(collection: IACollection? = nil, sort: CatalogSort? = nil) async {
        guard sourceFilter == .collections, let collection = collection ?? selectedCollection else { return }
        await catalogStore.searchAdvanced(
            collection.archiveQuery,
            sort: sort ?? collectionSort,
            collectionID: collection.id
        )
    }

    private func runSearch() async {
        let term = FindSearchLifecycle.normalized(catalogStore.query)
        // Cancel the previous source before dispatching exactly one request.
        cancelSearchRequests()
        preflightTask?.cancel()
        preflightTask = nil
        catalogStore.resetResultsForNavigation()
        let destination = sourceFilter.searchDestination(hasSelectedCollection: selectedCollection != nil)
        guard destination != .none, !term.isEmpty || destination == .collection else {
            searchLifecycle.reset()
            return
        }
        searchLifecycle.submit(draft: term)

        switch destination {
        case .collection:
            guard let selectedCollection else { return }
            let collectionQuery = term.isEmpty
                ? selectedCollection.archiveQuery
                : "(\(selectedCollection.archiveQuery)) AND (\(scopedQuery(term, includeCatalogScope: false)))"
            let store = catalogStore
            let sort = collectionSort
            librivoxTask = Task {
                guard !Task.isCancelled else { return }
                await store.searchAdvanced(collectionQuery, sort: sort, collectionID: selectedCollection.id)
            }
        case .librivox:
            let store = catalogStore
            let scope = searchScope
            let scoped = scopedQuery(term)
            librivoxTask = Task {
                guard !Task.isCancelled else { return }
                switch scope {
                case .all: await store.searchLibriVox(term)
                case .title, .author, .narrator: await store.searchAdvanced(scoped, sort: .popularity)
                }
            }
        case .gutenberg:
            let searchID = gutenbergSearchID
            gutenbergTask = Task { await searchGutenberg(term, searchID: searchID) }
        case .none:
            return
        }
        // Only one of these tasks can be created by the exclusive switch.
        let request = gutenbergTask ?? librivoxTask
        await withTaskCancellationHandler {
            await request?.value
        } onCancel: {
            request?.cancel()
        }
    }

    private func cancelSearchRequests() {
        collectionLoadTask?.cancel()
        collectionLoadTask = nil
        loadingCollectionID = nil
        lastCollectionLoadKey = nil
        librivoxTask?.cancel()
        librivoxTask = nil
        gutenbergTask?.cancel()
        gutenbergTask = nil
        invalidateGutenbergSearch()
    }

    private func searchGutenberg(_ term: String, searchID: UUID) async {
        guard sourceFilter == .gutenberg, gutenbergSearchID == searchID, !term.isEmpty, !Task.isCancelled else {
            return
        }
        gutenbergSearchID = searchID
        isSearchingGutenberg = true
        gutenbergResults = []
        defer {
            if gutenbergSearchID == searchID { isSearchingGutenberg = false }
        }

        // A first search can race the Discover `.task` that downloads the
        // mirror index. Load the cached snapshot and join/start one refresh
        // before deciding the mirror is unavailable, so a healthy mirror stays
        // the primary source and gutenberg.org is only a real fallback.
        await gutenbergIndex.prepareForSearch()
        guard gutenbergSearchID == searchID, !Task.isCancelled else { return }

        if gutenbergIndex.isAvailable {
            let results = await gutenbergIndex.search(term)
            guard gutenbergSearchID == searchID, !Task.isCancelled else { return }
            gutenbergResults = results
            return
        }

        do {
            // The client is nonisolated, so network and HTML/JSON parsing run
            // off the main actor; only the assignment below touches view state.
            let results = try await GutenbergCatalogClient().search(term)
            guard gutenbergSearchID == searchID, !Task.isCancelled else { return }
            gutenbergResults = results
        } catch {
            guard gutenbergSearchID == searchID, !Task.isCancelled else { return }
            gutenbergResults = []
            catalogStore.catalogError = Self.gutenbergErrorMessage(for: error)
        }
    }

    private static func gutenbergErrorMessage(for error: Error) -> String {
        guard let error = error as? GutenbergCatalogError else {
            return String(localized: "Project Gutenberg search failed: \(error.localizedDescription)")
        }
        switch error {
        case .temporarilyUnavailable:
            return String(localized: "Project Gutenberg is temporarily unavailable. Please try again later.")
        case .unexpectedResponse:
            return String(localized: "Project Gutenberg returned an unexpected response. Please try again.")
        case .httpStatus(let status):
            return String(localized: "Project Gutenberg search failed (HTTP \(status)).")
        }
    }

    private func invalidateGutenbergSearch() {
        gutenbergTask?.cancel()
        gutenbergTask = nil
        gutenbergSearchID = UUID()
        isSearchingGutenberg = false
        gutenbergResults = []
    }

    private var searchProgressLabel: String {
        switch sourceFilter {
        case .gutenberg: "Searching Project Gutenberg"
        case .librivox: "Searching LibriVox"
        case .collections: "Loading collection"
        }
    }

    private var gutenbergResultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Project Gutenberg", usesThreeSizeTypography: true)
            LazyVStack(spacing: 0) {
                ForEach(gutenbergResults) { book in
                    Button { selectedGutenbergBook = book } label: {
                        HStack(spacing: 12) {
                            CoverPlate(
                                title: book.title,
                                author: book.authorLine,
                                coverURL: book.coverURL,
                                size: 48,
                                shape: .portrait
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(book.title).voxFont(LibraryScreenTypography.card, weight: .semibold).foregroundStyle(Palette.ink)
                                Text(book.authorLine).voxFont(LibraryScreenTypography.card).foregroundStyle(Palette.ink2)
                                Text("READ WITH AI · PROJECT GUTENBERG").voxFont(LibraryScreenTypography.card, weight: .bold).foregroundStyle(Palette.brass)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(Palette.ink3)
                        }.padding(14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("discover.gutenberg.\(book.id)")
                }
            }.raisedSurface()
        }
    }

    private var gutenbergLoadingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Project Gutenberg", usesThreeSizeTypography: true)
            HStack(spacing: 12) {
                ProgressView()
                Text("Searching Project Gutenberg")
                    .voxFont(LibraryScreenTypography.controls)
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .raisedSurface()
            .accessibilityIdentifier("discover.gutenberg.loading")
        }
    }

    private func startOwnershipPreflight(for displayed: [InternetArchiveSearchResult]) {
        guard sourceFilter != .gutenberg, !displayed.isEmpty, catalogStore.catalogError == nil else { return }
        preflightTask?.cancel()
        let results = displayed
        let catalogStore = catalogStore
        let libraryStore = libraryStore
        preflightTask = Task {
            await catalogStore.reconcileLegacyOwnership(results: results, into: libraryStore)
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
        preflightTask?.cancel()
        preflightTask = nil
        searchLifecycle.reset()
        cancelSearchRequests()
        catalogStore.resetResultsForNavigation()
        catalogStore.query = ""
        searchScope = .all
        if sourceFilter == .collections, let selectedCollection {
            startCollectionLoad(selectedCollection, sort: collectionSort)
        }
    }

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        // Push immediately; CatalogBookDestinationView performs the metadata
        // import after navigation so the tap has instant visual feedback.
        selectedCatalogResult = CatalogResultRoute(result: result)
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

private enum DiscoverSearchScope: Hashable {
    case all
    case title
    case author
    case narrator
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
                    Text(collection.title).voxFont(LibraryScreenTypography.card, weight: .semibold).foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                }
                Text(collection.description).voxFont(LibraryScreenTypography.card).foregroundStyle(Palette.ink3).lineLimit(2)
                if let caption = approximateCountCaption { Text(caption).voxFont(LibraryScreenTypography.card, weight: .semibold).foregroundStyle(Palette.ink2) }
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
        .frame(minHeight: 196)
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
                .voxFont(LibraryScreenTypography.card, weight: .bold)
            Text("CURATED")
                .voxFont(LibraryScreenTypography.card, weight: .bold)
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

/// Single navigation value for a tapped catalog result so the destination
/// can never receive a stale or nil result.
private struct CatalogResultRoute: Identifiable, Hashable {
    let result: InternetArchiveSearchResult
    var id: String { result.identifier }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) } // hash-exempt: Hashable identity, not a visual hash
}
