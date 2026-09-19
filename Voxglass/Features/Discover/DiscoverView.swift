import SwiftUI
import VoxglassCore

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var showingNowPlaying: Bool
    @State private var selectedCollection: IACollection?
    @State private var collectionSort: CatalogSort = .popularity
    @StateObject private var coverStore = CollectionCoverStore(artwork: ArtworkService.shared)
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"
    @State private var showDownloadAllAlert = false
    @State private var importingIdentifier: String?
    // Advanced catalog filters belong to this discovery surface only. Do not
    // persist them as app-wide preferences or a choice here can silently
    // narrow another catalog surface later.
    @State private var soloOnly = false
    @State private var searchScope: DiscoverSearchScope = .all
    @State private var selectedCatalogBookID: UUID?
    @State private var showingHistory = false
    @State private var showSearch = false
    @State private var discoverScope: DiscoverBrowseScope = .collection
    @State private var showingCollectionInfo: IACollection?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VoxglassScreen(
            title: "Discover",
            headerTrailingContent: AnyView(discoverHeaderActions)
        ) {
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
            .navigationDestination(item: $selectedCatalogBookID) { bookID in
                BookPageView(book: libraryStore.book(withID: bookID), showingNowPlaying: $showingNowPlaying)
            }
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(showingNowPlaying: $showingNowPlaying)
                .environmentObject(libraryStore)
        }
        .sheet(item: $showingCollectionInfo) { collection in
            CollectionInfoSheet(
                collection: collection,
                resolvedCoverURL: coverStore.coverURL(for: collection),
                approximateCount: coverStore.count(for: collection)
            )
        }
        .alert("Discover Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
        .task {
            catalogStore.selectedLanguages = selectedLanguages
            let collections = IACollectionStore.collections(for: selectedCollectionIDs, languages: selectedLanguages)
            await coverStore.resolveCovers(for: collections, languages: selectedLanguages)
            await coverStore.resolveCounts(for: collections, languages: selectedLanguages)
        }
        .onChange(of: selectedLanguagesRaw) { _, _ in
            catalogStore.selectedLanguages = selectedLanguages
            Task {
                let collections = IACollectionStore.collections(for: selectedCollectionIDs, languages: selectedLanguages)
                await coverStore.resolveCovers(for: collections, languages: selectedLanguages, force: true)
                await coverStore.resolveCounts(for: collections, languages: selectedLanguages, force: true)
            }
        }
        .onChange(of: catalogStore.results) { _, results in
            ArtworkService.shared.prefetch(urls: results.map(\.coverURL), limit: 18)
        }
        .onChange(of: collectionSort) { _, _ in
            guard selectedCollection != nil else { return }
            Task { await runSearch() }
        }
        .onChange(of: searchScope) { _, _ in
            guard !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await runSearch() }
        }
        .onChange(of: discoverScope) { _, scope in
            let hasQuery = !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if scope == .all {
                guard selectedCollection != nil || hasQuery else { return }
                selectedCollection = nil
                if hasQuery {
                    Task { await runSearch() }
                } else {
                    catalogStore.resetResultsForNavigation()
                }
            } else {
                guard selectedCollection == nil || hasQuery else {
                    Task { await loadSelectedCollection() }
                    return
                }
                if hasQuery {
                    catalogStore.query = ""
                    searchScope = .all
                }
                catalogStore.resetResultsForNavigation()
            }
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
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(showSearch ? "Close search" : "Search Discover")
            .accessibilityIdentifier("discover.searchButton")

            Menu {
                Picker("Search in", selection: $searchScope) {
                    ForEach(DiscoverSearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Divider()
                Toggle("Solo narration", isOn: $soloOnly)
                if selectedCollection != nil {
                    Picker("Sort", selection: $collectionSort) {
                        ForEach(CatalogSort.availableSorts(for: selectedCollection ?? IACollectionStore.popular)) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    if selectedCollection?.isCurated == true, !catalogStore.activeCuratedManifest.isEmpty {
                        Text("Download all is available in collection details")
                            .scaledFont(size: 12)
                            .foregroundStyle(Palette.ink3)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Filter and sort")
            .accessibilityIdentifier("discover.filterButton")

            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Listening History")
            .accessibilityIdentifier("discover.historyButton")
        }
    }

    private var scopeBar: some View {
        Picker("Discover scope", selection: $discoverScope) {
            Text("All").tag(DiscoverBrowseScope.all)
            Text("Collection").tag(DiscoverBrowseScope.collection)
        }
        .pickerStyle(.segmented)
        .tint(Palette.brass)
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
            .scaledFont(size: 15)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .glassSurface(cornerRadius: 20)

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
                    .scaledFont(size: 12, weight: .semibold)
                Text(collection.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(1)
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
                        .scaledFont(size: 11, weight: .bold)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Clear selected collection")
                .accessibilityIdentifier("discover.selectedCollection.clear")
            }
            .foregroundStyle(Palette.brass)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.06))
            .accessibilityIdentifier("discover.selectedCollection")

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
                        resolvedCoverURL: coverStore.coverURL(for: collection),
                        approximateCount: coverStore.count(for: collection),
                        isSelected: false,
                        onSelect: { search(collection) },
                        onInfo: { showingCollectionInfo = collection }
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
                SectionTitle(title: resultsTitle)
                if selectedCollection != nil {
                    if selectedCollection?.isCurated == true {
                        curatedStatusBanner
                        downloadAllButton
                    }
                    if let collection = selectedCollection, collection.hasDescription {
                        collectionDescriptionView(collection)
                    }
                }

                if catalogStore.results.isEmpty {
                    if catalogStore.isSearching {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching LibriVox")
                                .scaledFont(size: 14)
                                .foregroundStyle(Palette.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassSurface(cornerRadius: 14)
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
                            title: "No Solo Narration Results",
                            message: "Try turning off the solo filter to see more audiobooks.",
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
                                        isLoading: importingIdentifier == result.identifier
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("discover.result.\(result.identifier)")
                                .accessibilityHint("Opens a paused preview with Play and Add to My Books actions")
                                .disabled(catalogStore.isSearching || importingIdentifier == result.identifier)

                                if index < results.count - 1 {
                                    VoxglassListDivider()
                                }
                            }
                        }
                        .glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))
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
            return "Search Results"
        }
        if let selectedCollection { return selectedCollection.title }
        return "Search Results"
    }

    private var curatedStatusBanner: some View {
        Text(curatedStatusMessage)
            .scaledFont(size: 11, weight: .medium)
            .foregroundStyle(Palette.brass)
            .padding(.bottom, 2)
            .accessibilityLabel(curatedStatusMessage)
    }

    private var curatedStatusMessage: String {
        switch collectionSort {
        case .curation:
            "Hand-picked list · shown in curation order"
        case .popularity:
            "Sorted by popularity"
        case .title:
            "Sorted by title"
        case .author:
            "Sorted by author"
        case .recordedDate:
            "Sorted by date"
        }
    }

    private var downloadAllButton: some View {
        VStack(spacing: 8) {
            if let progress = catalogStore.batchProgress {
                VStack(spacing: 4) {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                        HStack {
                            Text("Downloading \(progress.completed) of \(progress.total)")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(Palette.ink2)
                            Spacer()
                            Button("Cancel") {
                                catalogStore.cancelBatchDownload()
                            }
                            .scaledFont(size: 12, weight: .semibold)
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
                                .scaledFont(size: 14)
                            Text("Download All (\(manifestCount) items)")
                                .scaledFont(size: 13, weight: .semibold)
                        }
                        .foregroundStyle(Palette.brass)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .glassSurface(cornerRadius: 10, fill: Color.white.opacity(0.05))
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
                        .scaledFont(size: 11, weight: .bold)
                }
            }
            .scaledFont(size: 14, weight: .semibold)
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

    private func search(_ collection: IACollection) {
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedCollection = collection
            discoverScope = .collection
            showSearch = false
            searchFocused = false
            catalogStore.query = ""
        }
        let defaultSort = CatalogSort.defaultSort(for: collection)
        collectionSort = defaultSort
        Task { await loadSelectedCollection() }
    }

    private func loadSelectedCollection() async {
        guard let selectedCollection else { return }
        await catalogStore.searchAdvanced(
            selectedCollection.archiveQuery,
            sort: collectionSort,
            collectionID: selectedCollection.id
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
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }
        let existingBookIDs = Set(libraryStore.books.map(\.book.id))

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            // Browsing/previewing a catalog result must never silently land
            // it in My Books — only the book page's explicit "+" does that.
            // Existing saved books must retain their library state when opened
            // again from Discover (or a fallback catalog result).
            if !existingBookIDs.contains(imported.book.id) {
                await libraryStore.markBookPending(imported.book.id)
            }
            selectedCatalogBookID = imported.book.id
        }
    }

    @ViewBuilder
    private func collectionDescriptionView(_ collection: IACollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !collection.summaryLine.isEmpty {
                Text(collection.summaryLine)
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(collection.description)
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(12)
        .glassSurface(cornerRadius: 12)
        .padding(.bottom, 4)
    }

    private var selectedCollectionIDs: Set<String> {
        AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)
    }

    private var selectedLanguages: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
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
        case .all: return "All"
        case .title: return "Title"
        case .author: return "Author"
        case .narrator: return "Narrator"
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
    var resolvedCoverURL: URL?
    var approximateCount: Int?
    var isSelected: Bool
    var onSelect: () -> Void
    var onInfo: () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .top) {
                            CollectionArtworkView(
                                title: collection.title,
                                systemImage: collection.systemImage,
                                assetName: collection.assetName,
                                remoteImageURL: resolvedCoverURL
                            )

                            if collection.isCurated {
                                curatedBadge
                            }
                        }
                        .frame(width: proxy.size.width * 0.42, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            Text(collection.title)
                                .scaledFont(size: 15, weight: .bold)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                                .accessibilityIdentifier("collection.title")

                            Text(collection.subtitle)
                                .scaledFont(size: 11.5)
                                .foregroundStyle(Palette.ink3)
                                .lineLimit(3)

                            if let caption = approximateCountCaption {
                                Text(caption)
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(Palette.brass)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    Spacer(minLength: 0)
                    Button(action: onInfo) {
                        Image(systemName: "info.circle")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About \(collection.title)")
                    .accessibilityIdentifier("discover.collectionInfo.\(collection.id)")
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .glassSurface(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.brass : .clear, lineWidth: 2)
        }
    }

    private var curatedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "rosette")
                .scaledFont(size: 9, weight: .bold)
            Text("CURATED")
                .scaledFont(size: 9, weight: .bold)
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
            return "\(formatted) book\(count == 1 ? "" : "s")"
        }
        let rounded = Self.roundedToTwoSignificantFigures(count)
        let formatted = Self.formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return "~\(formatted) book\(rounded == 1 ? "" : "s")"
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
                        .scaledFont(size: 24, weight: .heavy)
                        .foregroundStyle(Palette.ink)
                    if let approximateCount, approximateCount > 0 {
                        Text("Approximately \(approximateCount.formatted()) books")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                    }
                    if !collection.summaryLine.isEmpty {
                        Text(collection.summaryLine)
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(Palette.ink2)
                    }
                    Text(collection.description)
                        .scaledFont(size: 14)
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
