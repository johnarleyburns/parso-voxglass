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
    @State private var isDescriptionExpanded = false
    @State private var showDownloadAllAlert = false
    @State private var importingIdentifier: String?
    // Advanced catalog filters belong to this discovery surface only. Do not
    // persist them as app-wide preferences or a choice here can silently
    // narrow another catalog surface later.
    @State private var soloOnly = false
    @State private var searchScope: DiscoverSearchScope = .all
    @State private var showAdvanced = false
    @State private var selectedCatalogBookID: UUID?
    @State private var showingHistory = false

    var body: some View {
        VoxglassScreen(
            title: "Discover",
            headerSecondaryActionSystemImage: "clock.arrow.circlepath",
            headerSecondaryAction: { showingHistory = true },
            headerSecondaryActionAccessibilityLabel: "Listening History"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                searchPanel
                collectionShelves
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
                    .accessibilityIdentifier("discover.catalogSearch")
                    .onSubmit { Task { await runSearch() } }

                if !catalogStore.query.isEmpty {
                    Button {
                        catalogStore.query = ""
                        catalogStore.resetResultsForNavigation()
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

            HStack(spacing: 8) {
                if let selectedCollection {
                    FilterChip(title: selectedCollection.title, isSelected: true) {
                        self.selectedCollection = nil
                        catalogStore.resetResultsForNavigation()
                    }
                }

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
                            Text("Download all is available under About")
                                .scaledFont(size: 12)
                                .foregroundStyle(Palette.ink3)
                        }
                    }
                } label: {
                    Label("Filter & sort", systemImage: "line.3.horizontal.decrease.circle")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(Palette.brass)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.06))
                }
                .accessibilityIdentifier("discover.filterMenu")

                if selectedCollection != nil {
                    Button(showAdvanced ? "Less" : "About") {
                        withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
                    }
                    .buttonStyle(.plain)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(Palette.ink3)
                }
                Spacer()
            }
        }
    }

    private var collectionShelves: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Featured Collections")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(IACollectionStore.collections(for: selectedCollectionIDs, languages: selectedLanguages)) { collection in
                        Button {
                            search(collection)
                        } label: {
                            ExploreCollectionCard(
                                collection: collection,
                                resolvedCoverURL: coverStore.coverURL(for: collection),
                                approximateCount: coverStore.count(for: collection),
                                isSelected: selectedCollection?.id == collection.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(collection.title)
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
            SectionTitle(title: resultsTitle)
            if selectedCollection != nil {
                if showAdvanced, selectedCollection?.isCurated == true {
                    curatedStatusBanner
                    downloadAllButton
                }
                if showAdvanced, let collection = selectedCollection, collection.hasDescription {
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
                        title: catalogStore.query.isEmpty ? "Browse Featured Collections" : "No Results Yet",
                        message: catalogStore.query.isEmpty
                            ? "Choose a Featured Collection or search above to find a book."
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
                        ForEach(results.indices, id: \.self) { index in
                            let result = results[index]
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

    private var resultsTitle: String {
        if !catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search Results"
        }
        if let selectedCollection { return selectedCollection.title }
        return "Browse the catalog"
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
        selectedCollection = collection
        catalogStore.query = ""
        isDescriptionExpanded = false
        showAdvanced = false
        let defaultSort = CatalogSort.defaultSort(for: collection)
        collectionSort = defaultSort
        Task { await catalogStore.searchAdvanced(collection.archiveQuery, sort: defaultSort, collectionID: collection.id) }
    }

    private func runSearch() async {
        let term = catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty || selectedCollection != nil else {
            catalogStore.resetResultsForNavigation()
            return
        }

        if let selectedCollection {
            let escaped = term.replacingOccurrences(of: "\"", with: "")
            let collectionQuery = term.isEmpty
                ? selectedCollection.archiveQuery
                : "(\(selectedCollection.archiveQuery)) AND (title:\"\(escaped)\" OR creator:\"\(escaped)\")"
            await catalogStore.searchAdvanced(collectionQuery, sort: collectionSort, collectionID: selectedCollection.id)
            return
        }

        switch searchScope {
        case .all:
            await catalogStore.searchLibriVox(term)
        case .title, .author, .narrator:
            await catalogStore.searchAdvanced(scopedQuery(term), sort: .popularity)
        }
    }

    private func scopedQuery(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "")
        let scopeClause = " AND \(LibriVoxCatalogScope.query)"

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

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            // Browsing/previewing a catalog result must never silently land
            // it in My Books — only the book page's explicit "+" does that.
            await libraryStore.markBookPending(imported.book.id)
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

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDescriptionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(isDescriptionExpanded ? "Less" : "More About this Collection")
                        .scaledFont(size: 12, weight: .medium)
                    Image(systemName: isDescriptionExpanded ? "chevron.up" : "chevron.right")
                        .scaledFont(size: 10, weight: .bold)
                }
                .foregroundStyle(Palette.brass)
            }
            .buttonStyle(.plain)

            if isDescriptionExpanded {
                Text(collection.description)
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.ink2)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

private struct ExploreCollectionCard: View {
    var collection: IACollection
    var resolvedCoverURL: URL?
    var approximateCount: Int?
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                CollectionArtworkView(
                    title: collection.title,
                    systemImage: collection.systemImage,
                    assetName: collection.assetName,
                    remoteImageURL: resolvedCoverURL
                )
                .frame(width: 190, height: 190)

                if collection.isCurated {
                    curatedBadge
                }
            }

            Text(collection.title)
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)

            Text(collection.subtitle)
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)

            if let caption = approximateCountCaption {
                Text(caption)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 190, alignment: .leading)
            }
        }
        .frame(width: 190, alignment: .topLeading)
        .padding(10)
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
