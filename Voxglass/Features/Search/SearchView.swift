import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var query = ""
    @State private var archiveURL = ""
    @State private var scope: SearchScope = .all
    @State private var importingIdentifier: String?

    var body: some View {
        VoxglassScreen(title: "Search") {
            VStack(alignment: .leading, spacing: 18) {
                searchPanel
                scopeChips
                archiveURLPanel
                if scope.showsLocal {
                    localResults
                }
                if scope.showsAuthors {
                    authorResults
                }
                if scope.showsArchive {
                    archiveResults
                }
            }
            .padding(.top, 12)
        }
        .alert("Search Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
    }

    private var searchPanel: some View {
        HStack(spacing: 10) {
            TextField("Title, author, or subject", text: $query)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit {
                    Task { await runSearch() }
                }

            Button {
                Task { await runSearch() }
            } label: {
                if catalogStore.isSearching {
                    ProgressView()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoxglassTheme.accent)
            .accessibilityLabel("Search")
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isSearching)
        }
    }

    private var scopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { searchScope in
                    FilterChip(
                        title: searchScope.title,
                        systemImage: searchScope.icon,
                        isSelected: scope == searchScope
                    ) {
                        scope = searchScope
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var archiveURLPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.headline)
                .foregroundStyle(VoxglassTheme.accent)
                .frame(width: 28)

            TextField("archive.org URL", text: $archiveURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
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
            .foregroundStyle(VoxglassTheme.accent)
            .accessibilityLabel("Add archive URL")
            .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
        }
        .padding(12)
        .glassPanel()
    }

    @ViewBuilder
    private var localResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "On This Device")

            if localMatches.isEmpty {
                EmptyStatePanel(
                    title: "No Local Results",
                    message: "Imported books matching this search will appear here.",
                    systemImage: "books.vertical"
                )
            } else {
                ForEach(localMatches.prefix(8)) { book in
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
    private var authorResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Authors")

            if localAuthorMatches.isEmpty && archiveAuthorMatches.isEmpty {
                EmptyStatePanel(
                    title: "No Authors",
                    message: "Author matches use local metadata and current archive results.",
                    systemImage: "person.2"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(localAuthorMatches, id: \.self) { author in
                        NavigationLink {
                            AuthorDetailView(authorName: author, showingNowPlaying: $showingNowPlaying)
                        } label: {
                            DisclosureListRow(
                                icon: "person.fill",
                                title: author,
                                detail: "Local author",
                                count: libraryStore.books(byAuthor: author).count
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(archiveAuthorMatches, id: \.self) { author in
                        DisclosureListRow(
                            icon: "person.crop.circle.badge.plus",
                            title: author,
                            detail: "Archive result author",
                            count: nil,
                            isEnabled: false
                        )
                    }
                }
                .glassPanel()
            }
        }
    }

    @ViewBuilder
    private var archiveResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "LibriVox and Archive")

            if catalogStore.isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching")
                        .font(.subheadline)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .glassPanel()
            } else if catalogStore.results.isEmpty {
                EmptyStatePanel(
                    title: "No Archive Results",
                    message: "Search by title, author, or subject to import public-domain audiobooks.",
                    systemImage: "globe"
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

    private var localMatches: [BookWithChapters] {
        let trimmed = normalizedQuery
        guard !trimmed.isEmpty else { return libraryStore.books }
        return libraryStore.books.filter { book in
            book.book.title.localizedCaseInsensitiveContains(trimmed)
                || book.book.authorLine.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var localAuthorMatches: [String] {
        let trimmed = normalizedQuery
        guard !trimmed.isEmpty else { return libraryStore.authorNames }
        return libraryStore.authorNames.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var archiveAuthorMatches: [String] {
        let trimmed = normalizedQuery
        let authors = Set(catalogStore.results.flatMap(\.creators))
        return authors
            .filter { author in
                !author.isEmpty && (trimmed.isEmpty || author.localizedCaseInsensitiveContains(trimmed))
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func runSearch() async {
        guard !normalizedQuery.isEmpty else { return }
        if scope.showsArchive {
            await catalogStore.searchLibriVox(normalizedQuery)
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

    private func addArchiveURL() async {
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            archiveURL = ""
            await playback.play(imported)
            showingNowPlaying = true
        }
    }
}

struct InternetArchiveResultRow: View {
    var result: InternetArchiveSearchResult
    var isImporting: Bool
    var importAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookArtworkView(title: result.title, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(result.authorLine)
                    .font(.subheadline)
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.78))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: importAction) {
                if isImporting {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoxglassTheme.accent)
            .accessibilityLabel("Import \(result.title)")
        }
        .padding(12)
        .glassPanel()
    }

    private var detailLine: String {
        var parts: [String] = []
        if let date = result.date, !date.isEmpty {
            parts.append(date)
        }
        if let downloads = result.downloads {
            parts.append("\(downloads) downloads")
        }
        if parts.isEmpty {
            parts.append(result.sourceKind.displayName)
        }
        return parts.joined(separator: " - ")
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all
    case local
    case librivox
    case authors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .local:
            return "Local"
        case .librivox:
            return "LibriVox"
        case .authors:
            return "Authors"
        }
    }

    var icon: String {
        switch self {
        case .all:
            return "rectangle.stack"
        case .local:
            return "iphone"
        case .librivox:
            return "waveform"
        case .authors:
            return "person.2"
        }
    }

    var showsLocal: Bool {
        self == .all || self == .local
    }

    var showsArchive: Bool {
        self == .all || self == .librivox
    }

    var showsAuthors: Bool {
        self == .all || self == .authors
    }
}
